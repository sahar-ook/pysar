#!/usr/bin/env python3
"""Local proxy from Pysar to Gemini 3.5 Transcribe Live, one take at a time.

sox records each take into a WAV file. While the key is held this daemon tails
that file and streams it to Google's Live API, so after release only the last
fraction of a second is left to recognise. Measured 2026-10-20 in
bench/transcribe_live.py on the 20 read-aloud takes: 10.5% of words wrong and
the final text 0.36 s (median) after the end of speech; the file model
(gemini-3.5-transcribe) took 2.6 s, and the local Parakeet + WhisperKit
ensemble gave 21.5% in 3-3.6 s.

The protocol is the bench's, unchanged: setup with inputAudioTranscription
{languageCodes, customVocabulary} and the server's own voice activity
detection off (push-to-talk), activityStart, 100 ms PCM chunks, activityEnd.
interimInputTranscription arrives while speaking; inputTranscription and
generationComplete arrive together after activityEnd (one final per take on
all 85 bench takes).

HTTP on 127.0.0.1:50063, JSON in and out:

  POST /start  {wav, terms, languages?} -> {id}   connects in the background
  GET  /partial?id=                     -> {text} heard so far, for the pill
  POST /stop   {id}                     -> {text, language, afterEndMs, setupMs, interim, key, keySwitch, error}
  POST /cancel {id}                     -> {ok}
  GET  /health                          -> {ok, model, inflight}

Anything short of a clean final answer - a socket error, no setupComplete, a
timeout, goAway, an empty transcript - comes back as `error` with `text` null,
and Pysar falls back to Parakeet. Nothing is ever guessed. One take at a time:
a second /start cancels the first. Standard library only, so it runs from
~/.pysar/venv under launchd (com.pysar.live) with nothing to install.

Two keys (2026-10-27): ~/.pysar/gemini-key-free, from an AI Studio project
without billing, goes first; ~/.pysar/gemini-key, the paid one, only when Google
refuses the free one. A refusal is what Google answers about the key rather
than the network: a 4xx on the handshake, or a close whose reason names quota,
exhaustion or the key (an invalid key closes 1007 "API key not valid", checked
2026-10-27; quota closes 1011 "You exceeded your current quota" / "Resource has
been exhausted" in forum reports). The same take is then streamed again from
the start of the WAV with the paid key, and the paid key stays until the next
midnight Pacific time, when Google resets daily quotas, or until the free key
file changes. /stop reports which key served (`key`) and why it switched
(`keySwitch`). No free key file: the paid key alone, as before.

  python3 server/live_server.py [--port 50063] [--model M] [--languages uk-UA,en-US]
                                [--stop-timeout 3.0]
  python3 server/live_server.py --selftest ~/.pysar/audio/<take>.wav
  python3 server/live_server.py --probe ~/.pysar/gemini-key-free   # does Live accept this key?
"""
import argparse, base64, json, os, re, select, socket, ssl, struct, sys, tempfile, threading, time, uuid
import urllib.request
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

RUN = Path.home() / ".pysar"
HOST = "generativelanguage.googleapis.com"
WS_PATH = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
CHUNK = 3200            # 100 ms of 16 kHz mono 16-bit PCM
BYTES_PER_S = 32000
TICK = 0.1              # how often the WAV is read while recording
DRAIN_TICK = 0.05       # after release: the file is done when two ticks in a row see no growth
DRAIN_MAX = 0.4         # ... or after this long, whatever sox is doing
SETUP_LIMIT = 10.0      # setupComplete: median 0.36 s on the bench (2026-10-20); 10 s means it is not coming
MAX_TAKE = 330.0        # Pysar stops a take at 300 s; a take never stopped is closed after this
MAX_HEADER = 4096       # the data chunk must start within this many bytes
MAX_TERMS = 100

# A close reason that is about the key, not the audio or the network.
# Not "exceeded" alone: "Deadline exceeded" is about time, not the key.
REFUSAL = re.compile(r"quota|exhausted|billing|api key|api_key|permission", re.I)
PACIFIC = ZoneInfo("America/Los_Angeles")

CYRILLIC = re.compile(r"[Ѐ-ӿ]")
LATIN = re.compile(r"[A-Za-z]")


def guess_language(text):
    """As server/parakeet_server.py does: Cyrillic means Ukrainian, anything else English."""
    return "uk" if len(CYRILLIC.findall(text)) > len(LATIN.findall(text)) else "en"


class Refused(Exception):
    """Google turned the key down on the handshake (HTTP 4xx)."""


class RateLimited(Refused):
    pass


def next_quota_reset(now=None):
    """Unix time of the next midnight Pacific: "Requests per day (RPD) quotas
    reset at midnight Pacific time" (ai.google.dev/gemini-api/docs/rate-limits)."""
    t = datetime.fromtimestamp(time.time() if now is None else now, PACIFIC)
    return (t.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)).timestamp()


# ── minimal RFC 6455 client (stdlib only; single thread, select-driven) ──────
# From bench/transcribe_live.py, unchanged.
class WS:
    def __init__(self, host, path, headers, timeout=15):
        raw = socket.create_connection((host, 443), timeout=timeout)
        self.s = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
               + "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n")
        self.s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = self.s.recv(65536)
            if not d:
                raise ConnectionError("closed during handshake")
            buf += d
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n")[0].decode(errors="replace")
        code = int(status.split()[1])
        if code != 101:
            try:
                self.s.settimeout(3); body = self.buf + self.s.recv(65536)
            except Exception:
                body = self.buf
            msg = f"handshake {status}: {body[:300].decode(errors='replace')}"
            if code == 429:
                raise RateLimited(msg)
            if 400 <= code < 500:
                raise Refused(msg)
            raise ConnectionError(msg)
        self.s.settimeout(0.05)
        self.frag, self.closed = b"", None

    def send(self, obj):
        self._frame(0x1, json.dumps(obj).encode())

    def _frame(self, op, data):
        n = len(data)
        hdr = bytes([0x80 | op])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        body = (int.from_bytes(data, "big") ^ int.from_bytes((mask * (n // 4 + 1))[:n], "big")).to_bytes(n, "big") if n else b""
        self.s.sendall(hdr + mask + body)

    def recv(self, timeout):
        """Messages that arrive within `timeout` s: list of ("msg", bytes) / ("close", code, reason)."""
        out = self._parse()
        if out or self.closed:
            return out
        if not self.s.pending():
            r, _, _ = select.select([self.s], [], [], max(0.0, timeout))
            if not r:
                return []
        try:
            d = self.s.recv(65536)
        except (socket.timeout, ssl.SSLWantReadError):
            return []
        if not d:
            self.closed = (1006, "connection dropped")
            return [("close", 1006, "connection dropped")]
        self.buf += d
        return self._parse()

    def _parse(self):
        out = []
        while len(self.buf) >= 2:
            b = self.buf
            fin, op, n, i = b[0] & 0x80, b[0] & 0x0F, b[1] & 0x7F, 2
            if n == 126:
                if len(b) < 4: break
                n, i = struct.unpack(">H", b[2:4])[0], 4
            elif n == 127:
                if len(b) < 10: break
                n, i = struct.unpack(">Q", b[2:10])[0], 10
            if b[1] & 0x80:
                i += 4  # servers do not mask; skip if one does
            if len(b) < i + n:
                break
            payload, self.buf = b[i:i + n], b[i + n:]
            if op == 0x9:
                self._frame(0xA, payload)
            elif op == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                self.closed = (code, payload[2:].decode(errors="replace"))
                out.append(("close",) + self.closed)
            elif op in (0x0, 0x1, 0x2):
                self.frag = payload if op else self.frag + payload
                if fin:
                    out.append(("msg", self.frag)); self.frag = b""
        return out

    def close(self):
        try:
            if not self.closed:
                self._frame(0x8, struct.pack(">H", 1000))
            self.s.close()
        except Exception:
            pass


# ── the WAV sox is writing ────────────────────────────────────────────────────
def data_offset(head):
    """Where the PCM starts, or None while the header is not all on disk yet.

    sox writes placeholder sizes until it closes the file (0x7ffff000 for the
    data chunk, checked 2026-10-20), so only the chunk layout is trusted: walk
    the chunks from byte 12 until `data`. A 16 kHz mono 16-bit fmt is required
    - that is what the Live API is told it gets.
    """
    if len(head) < 12:
        return None
    if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos = 12
    while True:
        if len(head) < pos + 8:
            return None
        cid, size = head[pos:pos + 4], struct.unpack("<I", head[pos + 4:pos + 8])[0]
        if cid == b"data":
            return pos + 8
        if cid == b"fmt ":
            if len(head) < pos + 8 + 16:
                return None
            tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", head[pos + 8:pos + 24])
            if tag not in (1, 0xFFFE) or (channels, rate, bits) != (1, 16000, 16):
                raise ValueError(f"need 16 kHz mono 16-bit PCM, got format {tag}, "
                                 f"{channels} ch, {rate} Hz, {bits} bit")
        pos += 8 + size + (size & 1)   # chunks are word-aligned
        if pos > MAX_HEADER:
            raise ValueError(f"no data chunk in the first {MAX_HEADER} bytes")


def split(data, size=CHUNK):
    return [data[i:i + size] for i in range(0, len(data), size)]


class Tail:
    """New samples of a WAV file that is still being written."""

    def __init__(self, path):
        self.path, self.pos, self.carry = path, None, b""

    def read(self):
        """Whole samples written since the last call; b"" while there are none."""
        try:
            with open(self.path, "rb") as f:
                if self.pos is None:
                    self.pos = data_offset(f.read(MAX_HEADER))
                    if self.pos is None:
                        return b""
                f.seek(self.pos)
                data = f.read()
        except FileNotFoundError:   # sox has not created it yet
            return b""
        self.pos += len(data)
        data = self.carry + data
        cut = len(data) - len(data) % 2   # never half a sample
        self.carry = data[cut:]
        return data[:cut]

    def size(self):
        try:
            return os.path.getsize(self.path)
        except OSError:
            return -1


# ── one take ──────────────────────────────────────────────────────────────────
def ms(a, b):
    return round((b - a) * 1000) if a is not None and b is not None else None


class Take:
    """`connect` is a socket factory, or a list of (key label, factory) tried in
    order while Google refuses the key; `on_refused(label, why)` hears each refusal."""

    def __init__(self, wav, terms, languages, model, connect, stop_timeout, log=None, on_refused=None):
        self.id = uuid.uuid4().hex[:12]
        self.wav, self.terms, self.languages, self.model = wav, terms, languages, model
        self.connects = [(None, connect)] if callable(connect) else list(connect)
        self.stop_timeout, self.log, self.on_refused = stop_timeout, log, on_refused
        self.lock = threading.Lock()
        self.finals, self.interim, self.interims = [], "", 0
        self.err, self.closed, self.refused = None, None, None
        self.key, self.switch = None, None
        self.t0 = self.attempt_t0 = time.time()
        self.setup_at = self.stop_at = self.t_end = self.complete_at = None
        self.started, self.pending, self.sent = False, b"", 0
        self.stopping, self.cancelled, self.done = threading.Event(), threading.Event(), threading.Event()

    def begin(self):
        threading.Thread(target=self._run, name=f"take-{self.id}", daemon=True).start()
        return self

    # ── called from HTTP threads ──
    def partial(self):
        with self.lock:
            return re.sub(r"\s+", " ", " ".join(t.strip() for t in self.finals + [self.interim])).strip()

    def stop(self):
        """Blocks until the final answer, an error, or the deadline."""
        if self.stop_at is None:
            self.stop_at = time.time()
        self.stopping.set()
        if not self.done.wait(DRAIN_MAX + self.stop_timeout + 0.5):
            self._fail("timeout")
            self.cancelled.set()
        return self.result()

    def cancel(self, why="cancelled"):
        if not self.done.is_set():
            self._fail(why)
        self.cancelled.set()

    def result(self):
        with self.lock:
            text = re.sub(r"\s+", " ", " ".join(t.strip() for t in self.finals)).strip()
            err = self.err
        return {"text": None if err else text, "language": None if err else guess_language(text),
                "afterEndMs": ms(self.t_end, self.complete_at), "setupMs": ms(self.t0, self.setup_at),
                "interim": self.interims, "key": self.key, "keySwitch": self.switch, "error": err}

    # ── the session thread: the only one that touches the socket ──
    def _fail(self, why, refused=False):
        with self.lock:
            if self.err is None:
                self.err = why
                if refused:
                    self.refused = why

    def _run(self):
        try:
            for i, (label, connect) in enumerate(self.connects):
                self.key = label
                self._attempt(connect)
                if not self.refused or i + 1 == len(self.connects) or self.cancelled.is_set():
                    break
                # The WAV holds the whole take, so the next key hears all of it.
                self.switch = f"{label} refused: {self.refused}"
                if self.on_refused:
                    self.on_refused(label, self.refused)
                self._restart()
        finally:
            self.done.set()
            if self.log:
                self.log(self._summary())

    def _attempt(self, connect):
        ws = None
        try:
            ws = connect()
            ws.send({"setup": {
                "model": self.model, "generationConfig": {"responseModalities": ["TEXT"]},
                "inputAudioTranscription": {"languageCodes": self.languages, "customVocabulary": self.terms},
                "realtimeInputConfig": {"automaticActivityDetection": {"disabled": True}}}})
            self._stream(ws)
        except Refused as e:
            self._fail(f"{type(e).__name__}: {e}", refused=True)
        except Exception as e:
            self._fail(f"{type(e).__name__}: {e}")
        finally:
            if ws is not None:
                ws.close()

    def _restart(self):
        """Forgets the refused session; the time limits that matter to Pysar (stop_at) stay."""
        with self.lock:
            self.finals, self.interim = [], ""
            self.err, self.closed, self.refused = None, None, None
        self.attempt_t0 = time.time()
        self.setup_at = self.t_end = self.complete_at = None
        self.started, self.pending, self.sent = False, b"", 0

    def _handle(self, items):
        for it in items:
            now = time.time()
            if it[0] == "close":
                self.closed = (it[1], it[2])
                if self.complete_at is None:
                    # 1007/1008 before setupComplete: the key or the model was not accepted
                    refused = bool(REFUSAL.search(it[2] or "")) or (it[1] in (1007, 1008) and self.setup_at is None)
                    self._fail(f"close {it[1]}: {it[2]}" if it[2] else f"close {it[1]}", refused)
                continue
            m = json.loads(it[1])
            if "goAway" in m:
                self._fail(f"goAway {json.dumps(m['goAway'])}")
            if "setupComplete" in m and self.setup_at is None:
                self.setup_at = now
            sc = m.get("serverContent") or {}
            with self.lock:
                if sc.get("interimInputTranscription"):
                    self.interims += 1
                    self.interim = sc["interimInputTranscription"].get("text", "")
                if sc.get("inputTranscription") is not None and "text" in sc["inputTranscription"]:
                    self.finals.append(sc["inputTranscription"]["text"])
                    self.interim = ""   # the final supersedes the interim of its segment
            # push-to-talk ends with generationComplete, never turnComplete (bench)
            if (sc.get("generationComplete") or sc.get("turnComplete")) and self.t_end is not None \
                    and self.complete_at is None:
                self.complete_at = now

    def _wait(self, ws, until):
        """Handles messages until `until`. False once the take is over: error, cancel, closed socket."""
        while True:
            if self.cancelled.is_set():
                self._fail("cancelled")
            if self.err:
                return False
            left = until - time.time()
            if left <= 0:
                return True
            self._handle(ws.recv(min(left, 0.05)))

    def _feed(self, ws, data):
        """Sends new audio, or holds it until setupComplete; order is kept either way."""
        self.pending += data
        if self.setup_at is None:
            return
        if not self.started:
            ws.send({"realtimeInput": {"activityStart": {}}})
            self.started = True
        for chunk in split(self.pending):
            ws.send({"realtimeInput": {"audio": {"data": base64.b64encode(chunk).decode(),
                                                 "mimeType": "audio/pcm;rate=16000"}}})
            self.sent += len(chunk)
        self.pending = b""

    def _stream(self, ws):
        tail = Tail(self.wav)
        next_read = time.time()
        while not self.stopping.is_set():
            if not self._wait(ws, min(next_read, time.time() + 0.05)):
                return
            now = time.time()
            if self.setup_at is None and now - self.attempt_t0 > SETUP_LIMIT:
                return self._fail("no setupComplete")
            if now - self.t0 > MAX_TAKE:
                return self._fail(f"no /stop within {MAX_TAKE:.0f} s")
            self._feed(ws, tail.read() if now >= next_read else b"")
            if now >= next_read:
                next_read = now + TICK

        # Released. sox flushes its last block when it gets SIGINT; the file is
        # complete once it stops growing.
        self.drain_from = time.time()
        last, still = tail.size(), 0
        while still < 2 and time.time() - self.drain_from < DRAIN_MAX:
            if not self._wait(ws, time.time() + DRAIN_TICK):
                return
            size = tail.size()
            still, last = (still + 1 if size == last else 0), size
            self._feed(ws, tail.read())
        self._feed(ws, tail.read())

        deadline = self.stop_at + DRAIN_MAX + self.stop_timeout
        while self.setup_at is None:   # the whole take was spoken before the setup answer
            if time.time() >= deadline:
                return self._fail("no setupComplete")
            if not self._wait(ws, min(deadline, time.time() + 0.05)):
                return
            self._feed(ws, b"")
        ws.send({"realtimeInput": {"activityEnd": {}}})
        self.t_end = time.time()

        until = min(self.t_end + self.stop_timeout, deadline)
        while self.complete_at is None:
            if time.time() >= until:
                return self._fail(f"timeout: no generationComplete {until - self.t_end:.1f} s after activityEnd")
            if not self._wait(ws, min(until, time.time() + 0.05)):
                return
        if not self.result()["text"]:
            self._fail("empty transcript")

    def _summary(self):
        """One log line. Timings and sizes only - never the text."""
        r = self.result()
        f = lambda v: "-" if v is None else f"{v} ms"
        drain = ms(getattr(self, "drain_from", None), self.t_end)
        return (f"take {self.id} {os.path.basename(self.wav)}"
                + (f" [{self.key} key]" if self.key else "")
                + (f" ({self.switch})" if self.switch else "")
                + f": setup {f(r['setupMs'])}, "
                f"audio {self.sent / BYTES_PER_S:.1f} s sent, drain {f(drain)}, after end {f(r['afterEndMs'])}, "
                f"interim {self.interims}, finals {len(self.finals)}, "
                + (f"error: {r['error']}" if r["error"] else f"{len(r['text'])} chars [{r['language']}]")
                + (f", close {self.closed[0]}" if self.closed else ""))


# ── HTTP ──────────────────────────────────────────────────────────────────────
def read_key(path):
    try:   # read per take, so a new key works without a restart
        return path.read_text().strip() if path else ""
    except OSError:
        return ""


class Live:
    def __init__(self, model, languages, stop_timeout, key_file, log_file, connect=None, free_key_file=None):
        self.model, self.languages, self.stop_timeout = model, languages, stop_timeout
        self.key_file, self.log_file = Path(key_file), Path(log_file)
        self.free_key_file = Path(free_key_file) if free_key_file else None
        self.connect = connect   # tests pass a fake socket factory
        self.lock = threading.Lock()
        self.take = None
        self.last_log = None
        self.free_refused = None   # (free key, until) after Google refused it

    def keys(self):
        """[(label, key)] in the order to try: free unless refused since the last quota reset, then paid."""
        out = []
        free = read_key(self.free_key_file)
        with self.lock:
            refused = self.free_refused
        if free and not (refused and refused[0] == free and time.time() < refused[1]):
            out.append(("free", free))
        paid = read_key(self.key_file)
        if paid:
            out.append(("paid", paid))
        return out

    def refused(self, key, why):
        until = next_quota_reset()
        with self.lock:
            self.free_refused = (key, until)
        self.log(f"free key refused ({why}); paid key until {time.strftime('%Y-%m-%d %H:%M', time.localtime(until))}")

    def log(self, line):
        self.last_log = line
        try:
            with open(self.log_file, "a") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")
        except OSError:
            pass

    def start(self, wav, terms, languages):
        connect, on_refused = self.connect, None
        if connect is None:
            keys = self.keys()
            if not keys:
                return None, f"no Gemini key in {self.key_file}"
            connect = [(label, lambda key=key: WS(HOST, WS_PATH, {"x-goog-api-key": key}, timeout=10))
                       for label, key in keys]
            free = dict(keys).get("free")
            on_refused = lambda label, why: self.refused(free, why) if label == "free" else None
        with self.lock:
            if self.take is not None and not self.take.done.is_set():
                self.take.cancel("replaced by a new take")
            self.take = Take(wav, terms, languages or self.languages, self.model, connect,
                             self.stop_timeout, self.log, on_refused).begin()
            return self.take, None

    def find(self, tid):
        with self.lock:
            return self.take if self.take is not None and self.take.id == tid else None

    def inflight(self):
        with self.lock:
            return int(self.take is not None and not self.take.done.is_set())


def make_handler(live):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):   # /partial every 0.4 s would drown the log
            pass

        def _json(self, code, payload):
            raw = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return None
            return body if isinstance(body, dict) else None

        def do_GET(self):
            url = urlparse(self.path)
            if url.path in ("/health", "/"):
                return self._json(200, {"ok": True, "model": live.model, "inflight": live.inflight()})
            if url.path == "/partial":
                take = live.find((parse_qs(url.query).get("id") or [""])[0])
                if take is None:
                    return self._json(404, {"text": "", "error": "unknown take"})
                return self._json(200, {"text": take.partial()})
            self._json(404, {"error": "unknown path"})

        def do_POST(self):
            body = self._body()
            if body is None:
                return self._json(400, {"error": "body is not a JSON object"})
            if self.path == "/start":
                wav = body.get("wav")
                if not isinstance(wav, str) or not wav:
                    return self._json(400, {"error": "no wav"})
                terms = [t.strip() for t in body.get("terms") or [] if isinstance(t, str) and t.strip()][:MAX_TERMS]
                langs = [l for l in body.get("languages") or [] if isinstance(l, str) and l]
                take, err = live.start(wav, terms, langs)
                if take is None:
                    live.log(f"start refused: {err}")
                    return self._json(503, {"error": err})
                return self._json(200, {"id": take.id})
            if self.path == "/stop":
                take = live.find(body.get("id"))
                if take is None:
                    return self._json(404, {"text": None, "language": None, "afterEndMs": None,
                                            "setupMs": None, "interim": 0, "error": "unknown take"})
                return self._json(200, take.stop())
            if self.path == "/cancel":
                take = live.find(body.get("id"))
                if take is not None:
                    take.cancel()
                return self._json(200, {"ok": True})
            self._json(404, {"error": "unknown path"})

    return Handler


def serve(live, host, port):
    srv = ThreadingHTTPServer((host, port), make_handler(live))
    srv.daemon_threads = True
    return srv


# ── selftest: a real take, written the way sox writes it ─────────────────────
def selftest(src, live):
    srv = serve(live, "127.0.0.1", 0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"

    def call(path, body=None):
        req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            return json.loads(e.read() or b"{}")

    raw = Path(src).read_bytes()
    off = data_offset(raw)
    if off is None:
        sys.exit(f"{src}: no data chunk")
    # sox's placeholders until it closes the file (seen 2026-10-20 on sox 14.4)
    head = bytearray(raw[:off])
    head[4:8], head[off - 4:off] = struct.pack("<I", 0x7FFFF024), struct.pack("<I", 0x7FFFF000)
    pcm = raw[off:]
    dictionary = RUN / "dictionary.txt"
    terms = [l.strip() for l in dictionary.read_text().splitlines()
             if l.strip() and not l.startswith("#")][:MAX_TERMS] if dictionary.exists() else []

    tmp = Path(tempfile.mkdtemp()) / "selftest.wav"
    print(f"selftest: {Path(src).name}, {len(pcm) / BYTES_PER_S:.2f} s of audio, {len(terms)} terms, "
          f"written to {tmp} at real-time pace")
    started = call("/start", {"wav": str(tmp), "terms": terms})
    print(f"  /start  -> {started}")
    if "id" not in started:
        sys.exit(1)
    t0 = time.time()
    with open(tmp, "wb") as f:
        f.write(head); f.flush()
        for i, at in enumerate(range(0, len(pcm), CHUNK)):
            time.sleep(max(0.0, t0 + (i + 1) * TICK - time.time()))
            f.write(pcm[at:at + CHUNK]); f.flush()
            if i % 10 == 9:
                print(f"  /partial at {time.time() - t0:4.1f} s -> {call('/partial?id=' + started['id'])['text']!r}")
        f.seek(0); f.write(raw[:off]); f.flush()   # the real sizes, as sox writes them on SIGINT
    t_stop = time.time()
    r = call("/stop", {"id": started["id"]})
    stop_ms = round((time.time() - t_stop) * 1000)
    print(f"  /stop   -> {json.dumps(r, ensure_ascii=False)}")
    print(f"text       {r.get('text')!r}")
    print(f"afterEndMs {r.get('afterEndMs')}   setupMs {r.get('setupMs')}   interim {r.get('interim')}   "
          f"/stop round trip {stop_ms} ms   key {r.get('key')}   keySwitch {r.get('keySwitch')!r}   "
          f"error {r.get('error')!r}")
    print(f"log        {live.last_log}")
    print(f"health     {call('/health')}")
    srv.shutdown()
    tmp.unlink(); tmp.parent.rmdir()
    ok = bool(r.get("text")) and r.get("afterEndMs") is not None and r["afterEndMs"] < 1000
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


# ── probe: does the Live model accept a key? No audio, nothing billed ─────────
def probe(key_file, model):
    key = read_key(Path(key_file))
    if not key:
        print(f"no key in {key_file}")
        return 1
    try:
        ws = WS(HOST, WS_PATH, {"x-goog-api-key": key}, timeout=10)
    except Exception as e:
        print(f"{model}: refused on connect - {type(e).__name__}: {e}")
        return 1
    try:
        ws.send({"setup": {"model": model, "generationConfig": {"responseModalities": ["TEXT"]},
                           "inputAudioTranscription": {"languageCodes": ["uk-UA"]},
                           "realtimeInputConfig": {"automaticActivityDetection": {"disabled": True}}}})
        deadline = time.time() + SETUP_LIMIT
        while time.time() < deadline:
            for it in ws.recv(0.2):
                if it[0] == "close":
                    print(f"{model}: refused - close {it[1]}: {it[2]}")
                    return 1
                if "setupComplete" in json.loads(it[1]):
                    print(f"{model}: OK, the key is accepted")
                    return 0
        print(f"{model}: no setupComplete in {SETUP_LIMIT:.0f} s")
        return 1
    finally:
        ws.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=50063)
    ap.add_argument("--model", default="models/gemini-3.5-transcribe-live")
    ap.add_argument("--languages", default="uk-UA,en-US")
    ap.add_argument("--stop-timeout", type=float, default=3.0,
                    help="seconds after activityEnd to wait for the final transcript")
    ap.add_argument("--key-file", default=str(RUN / "gemini-key"), help="the paid key, used when the free one is refused")
    ap.add_argument("--free-key-file", default=str(RUN / "gemini-key-free"),
                    help="a key from a project without billing, tried first")
    ap.add_argument("--log", default=str(RUN / "live.log"))
    ap.add_argument("--selftest", metavar="WAV", help="stream one recorded take through a private server and exit")
    ap.add_argument("--probe", metavar="KEY_FILE", help="check that the Live model accepts this key, and exit")
    a = ap.parse_args()
    if a.probe:
        sys.exit(probe(a.probe, a.model))

    live = Live(a.model, [l.strip() for l in a.languages.split(",") if l.strip()], a.stop_timeout,
                a.key_file, a.log, free_key_file=a.free_key_file)
    if a.selftest:
        sys.exit(selftest(a.selftest, live))
    srv = serve(live, a.host, a.port)
    live.log(f"listening on http://{a.host}:{a.port}, {a.model}, {a.languages}, stop timeout {a.stop_timeout} s")
    srv.serve_forever()


if __name__ == "__main__":
    main()
