#!/usr/bin/env python3
"""Gemini 3.5 Transcribe Live (streaming, WebSocket) against the file model on
your own takes - the audio goes to Google.

Each take is streamed as a live microphone would deliver it: 100 ms PCM chunks,
each sent once its 100 ms has "been recorded" (paced to wall clock). After the
last chunk the end signal goes out (t_end); t_final is when the last finalized
transcript of the take arrives. The same take then goes to the file model
(gemini-3.5-transcribe, as in bench/transcribe.py) for a side-by-side latency.

  read  the 20 read-aloud takes from 2026-10-20T16:20:14, WER against reference2.txt
  real  the 65 real takes bench/cloud.py used, live text next to what Pysar delivered

Results, which hold your dictation, go to ~/.pysar/bench/transcribe-live.{tsv,out}.

  python3 -I bench/transcribe_live.py [--set read|real|both] [--mode manual|hybrid]
                                      [--limit N] [--probe]

  manual  push-to-talk: server VAD off, activityStart ... activityEnd (key hold)
  hybrid  server VAD on, audioStreamEnd when the key is released
  probe   print every server message of the first take; no file mode, no outputs
"""
import argparse, base64, json, os, re, select, socket, ssl, struct, sys, time, urllib.error, urllib.request, wave
from pathlib import Path

RUN = Path.home() / ".pysar"
OUT = RUN / "bench"
HERE = Path(__file__).parent
KEY = (RUN / "gemini-key").read_text().strip()
TERMS = [l.strip() for l in (RUN / "dictionary.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]
LANGS = ["uk-UA", "en-US"]
HOST = "generativelanguage.googleapis.com"
WS_PATH = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
LIVE_MODEL = "models/gemini-3.5-transcribe-live"
CHUNK = 3200            # 100 ms of 16 kHz mono 16-bit PCM
BYTES_PER_S = 32000
FIRST_READ = "2026-10-20T16:20:14"


class RateLimited(Exception):
    pass


# ── minimal RFC 6455 client (stdlib only; single thread, select-driven) ──────
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


# ── live mode ─────────────────────────────────────────────────────────────────
def pcm_of(wav):
    with wave.open(str(wav)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2), wav
        return w.readframes(w.getnframes())


def live_once(wav, mode, probe=False):
    pcm = pcm_of(wav)
    ev = {"interim": 0, "finals": [], "t_final": None, "turn_complete": None, "usage": {},
          "err": "", "close": None, "first_interim": None}
    t0 = time.time()

    def handle(items, now):
        for it in items:
            if it[0] == "close":
                ev["close"] = (it[1], it[2])
                if it[1] != 1000:
                    reason = it[2] or ""
                    if it[1] == 1011 and re.search(r"quota|exhaust|rate|429", reason, re.I):
                        raise RateLimited(f"close {it[1]}: {reason}")
                    ev["err"] = f"close {it[1]}: {reason}"
                continue
            m = json.loads(it[1])
            if probe:
                print(f"  +{now - t0:6.2f}s {json.dumps(m, ensure_ascii=False)[:400]}")
            if "usageMetadata" in m:
                ev["usage"] = m["usageMetadata"]
            if "goAway" in m:
                ev["err"] = f"goAway {m['goAway']}"
            sc = m.get("serverContent") or {}
            if sc.get("interimInputTranscription"):
                ev["interim"] += 1
                ev["first_interim"] = ev["first_interim"] or now
            if sc.get("inputTranscription") is not None and "text" in sc["inputTranscription"]:
                ev["finals"].append((now, sc["inputTranscription"]["text"]))
                ev["t_final"] = now
            if sc.get("turnComplete") or sc.get("generationComplete"):
                ev["turn_complete"] = now   # push-to-talk ends with generationComplete, never turnComplete
            if "setupComplete" in m:
                ev["setup"] = now

    def pump(until, stop=lambda: False):
        while not ev["close"] and not stop():
            left = until - time.time()
            if left <= 0:
                return
            handle(ws.recv(min(left, 0.05)), time.time())

    ws = WS(HOST, WS_PATH, {"x-goog-api-key": KEY})
    try:
        setup = {"model": LIVE_MODEL, "generationConfig": {"responseModalities": ["TEXT"]},
                 "inputAudioTranscription": {"languageCodes": LANGS, "customVocabulary": TERMS}}
        if mode == "manual":
            setup["realtimeInputConfig"] = {"automaticActivityDetection": {"disabled": True}}
        ws.send({"setup": setup})
        pump(time.time() + 15, lambda: "setup" in ev)
        if "setup" not in ev:
            ev["err"] = ev["err"] or "no setupComplete"
            return ev | {"t0": t0, "t_end": None, "audio_s": len(pcm) / BYTES_PER_S}
        if mode == "manual":
            ws.send({"realtimeInput": {"activityStart": {}}})
        start = time.time()
        for i in range(0, len(pcm), CHUNK):
            chunk = pcm[i:i + CHUNK]
            pump(start + (i + len(chunk)) / BYTES_PER_S)    # the chunk exists once it has been "recorded"
            if ev["close"]:
                break
            ws.send({"realtimeInput": {"audio": {"data": base64.b64encode(chunk).decode(),
                                                 "mimeType": "audio/pcm;rate=16000"}}})
        if not ev["close"]:
            ws.send({"realtimeInput": {"activityEnd": {}} if mode == "manual" else {"audioStreamEnd": True}})
        t_end = time.time()
        # Done when generation/turn completes after the end signal; else wait out 10 s of silence (30 s cap).
        while not ev["close"] and time.time() - t_end < 30:
            if ev["turn_complete"] and ev["turn_complete"] >= t_end:
                pump(time.time() + 1.0)  # catch a straggling final or usage that may follow
                break
            last = max([t for t, _ in ev["finals"]] + [t_end])
            if time.time() - last > 10:
                break
            pump(time.time() + 0.1)
        if not ev["close"] and not (ev["turn_complete"] and ev["turn_complete"] >= t_end):
            ev["err"] = ev["err"] or "no generationComplete/turnComplete after end"
        return ev | {"t0": t0, "t_end": t_end, "start": start, "audio_s": len(pcm) / BYTES_PER_S}
    finally:
        ws.close()


def live(wav, mode, probe=False):
    for attempt in range(6):
        try:
            ev = live_once(wav, mode, probe)
            ev["retries"] = attempt
            return ev
        except RateLimited as e:
            if attempt == 5:
                return {"err": str(e), "finals": [], "retries": attempt}
            print(f"   (live rate-limited: {e}; waiting {15 * (attempt + 1)} s)", flush=True)
            time.sleep(15 * (attempt + 1))
        except Exception as e:
            return {"err": f"{type(e).__name__}: {e}", "finals": [], "retries": attempt}


def live_text(ev):
    return re.sub(r"\s+", " ", " ".join(t.strip() for _, t in ev.get("finals", []))).strip()


# ── file mode: transcribe() from bench/transcribe.py; latency of the successful attempt only ──
FILE_OFF = []  # set once the file model's daily request cap is hit: no point retrying for the rest of the run


def transcribe(wav):
    if FILE_OFF:
        return f"ERR: skipped, {FILE_OFF[0]}", 0.0, {}, 0
    body = {"model": "gemini-3.5-transcribe",
            "input": [{"type": "audio", "data": base64.b64encode(wav.read_bytes()).decode(), "mime_type": "audio/wav"}],
            "generation_config": {"transcription_config": {"custom_vocabulary": TERMS,
                                                           "language_codes": LANGS}}}
    data = json.dumps(body).encode()
    for attempt in range(6):
        t0 = time.time()
        try:
            req = urllib.request.Request("https://generativelanguage.googleapis.com/v1beta/interactions", data=data,
                                         headers={"Content-Type": "application/json", "x-goog-api-key": KEY})
            with urllib.request.urlopen(req, timeout=90) as r:
                resp = json.loads(r.read())
            dt = time.time() - t0
            break
        except urllib.error.HTTPError as e:
            msg = e.read()[:300].decode(errors="replace")
            if e.code == 429 and "per day" in msg:
                FILE_OFF.append("file model daily cap (100 requests/day on Tier 1)")
            if e.code != 429 or attempt == 5 or FILE_OFF:
                return f"ERR: HTTP {e.code} {msg[:200]}", time.time() - t0, {}, attempt
            print(f"   (file rate-limited; waiting {15 * (attempt + 1)} s)", flush=True)
            time.sleep(15 * (attempt + 1))
        except Exception as e:
            return f"ERR: {type(e).__name__}: {e}", time.time() - t0, {}, attempt
    text = " ".join(c.get("text", "") for st in resp.get("steps", []) for c in st.get("content", []))
    return text.strip(), dt, resp.get("usage", {}), attempt


def words(t):
    return [w for w in re.split(r"[^\w']+", t.lower().replace("’", "'")) if w]


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1])); prev, d[j] = d[j], cur
    return d[len(h)], len(r)


# ── take sets ─────────────────────────────────────────────────────────────────
def journal():
    rows = []
    for l in open(RUN / "takes.jsonl"):
        try:
            rows.append(json.loads(l))
        except Exception:
            pass
    return rows


def read_set():
    ref = [l.split("\t")[0] for l in (HERE / "reference2.txt").read_text().splitlines()
           if l.strip() and not l.startswith("#")]
    rows = [r for r in journal() if r.get("outcome") == "ok" and r.get("transcript") and r["at"] >= FIRST_READ][:len(ref)]
    return [("read", RUN / r["audio"], t) for t, r in zip(ref, rows)]


def real_set():
    by_stem = {Path(r["audio"]).stem: r for r in journal() if r.get("audio")}
    stems = [json.loads(l)["take"] for l in open(OUT / "cloud.jsonl")] if (OUT / "cloud.jsonl").exists() else []
    stems = [s for s in stems if (RUN / "audio" / f"{s}.wav").exists() and s in by_stem]
    if not stems:  # cloud.py's set is gone: the most recent 60 real ok takes
        stems = [Path(r["audio"]).stem for r in journal() if r.get("outcome") == "ok" and r.get("audio")
                 and r["at"] < FIRST_READ][-60:]
    out = []
    for s in stems:
        tr = by_stem[s].get("transcript")
        p = RUN / "transcripts" / f"{tr}.txt"
        out.append(("real", RUN / "audio" / f"{s}.wav", p.read_text().strip() if tr and p.exists() else ""))
    return out


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else float("nan")


def one_line(t):
    return re.sub(r"\s+", " ", t or "").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="both", choices=["read", "real", "both"])
    ap.add_argument("--mode", default="manual", choices=["manual", "hybrid"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--resume", action="store_true", help="keep error-free rows of the last TSV, run the rest")
    a = ap.parse_args()

    takes = (read_set() if a.set in ("read", "both") else []) + (real_set() if a.set in ("real", "both") else [])
    if a.limit:
        takes = takes[:a.limit]
    if a.probe:
        kind, wav, ref = takes[0]
        print(f"probe {wav.name} mode={a.mode}")
        ev = live(wav, a.mode, probe=True)
        lat = ev["t_final"] - ev["t_end"] if ev.get("t_final") and ev.get("t_end") else None
        print(f"t_end +{ev.get('t_end', 0) - ev.get('t0', 0):.2f}s  latency_after_end {lat}  err {ev.get('err')!r}"
              f"\nlive: {live_text(ev)}\nref:  {ref}")
        return

    OUT.mkdir(parents=True, exist_ok=True)
    log = open(OUT / "transcribe-live.out", "a" if a.resume else "w")

    def say(s=""):
        print(s, flush=True); log.write(s + "\n"); log.flush()

    cols = ["set", "take", "audio_s", "mode", "setup_s", "latency_after_end_s", "session_s", "file_s",
            "interim_msgs", "final_msgs", "live_retries", "file_retries", "live_err", "file_err",
            "live_tokens_in", "live_tokens_out", "file_tokens_in", "file_tokens_out",
            "ref_words", "live_wer_err", "file_wer_err", "live_text", "file_text", "reference_or_delivered"]
    done = {}
    if a.resume and (OUT / "transcribe-live.tsv").exists():
        for line in (OUT / "transcribe-live.tsv").read_text().splitlines()[1:]:
            r = dict(zip(cols, line.split("\t")))
            for c in ("audio_s", "setup_s", "latency_after_end_s", "session_s", "file_s"):
                r[c] = float(r[c]) if r[c] else None
            for c in ("interim_msgs", "final_msgs", "live_retries", "file_retries", "live_tokens_in",
                      "live_tokens_out", "file_tokens_in", "file_tokens_out", "ref_words", "live_wer_err", "file_wer_err"):
                r[c] = int(r[c]) if r[c] else ("" if c in ("ref_words", "live_wer_err", "file_wer_err") else 0)
            if not r["live_err"] and not r["file_err"] and r["latency_after_end_s"] is not None:
                done[r["take"]] = r
    tsv = open(OUT / "transcribe-live.tsv", "w")
    tsv.write("\t".join(cols) + "\n")

    def put(row):
        tsv.write("\t".join(one_line(f"{row[c]:.3f}" if isinstance(row[c], float) else str(row[c] if row[c] is not None else ""))
                            for c in cols) + "\n"); tsv.flush()
    say(f"gemini-3.5-transcribe-live ({a.mode}) vs gemini-3.5-transcribe (file); {len(takes)} takes; "
        f"vocabulary {len(TERMS)} terms; languages {LANGS}; started {time.strftime('%Y-%m-%d %H:%M:%S')}"
        + (f"; resumed, {sum(w.stem in done for _, w, _ in takes)} error-free takes kept from the previous run" if a.resume else ""))
    rows = []
    for kind, wav, ref in takes:
        if wav.stem in done:
            rows.append(done[wav.stem]); put(done[wav.stem])
            continue
        ev = live(wav, a.mode)
        ltext = live_text(ev)
        lat = ev["t_final"] - ev["t_end"] if ev.get("t_final") and ev.get("t_end") else None
        sess = (ev["t_final"] - ev["t0"]) if ev.get("t_final") else None
        setup = (ev["setup"] - ev["t0"]) if ev.get("setup") else None
        ftext, fdt, fusage, fretries = transcribe(wav)
        u = ev.get("usage") or {}
        row = {"set": kind, "take": wav.stem, "audio_s": round(len(pcm_of(wav)) / BYTES_PER_S, 2), "mode": a.mode,
               "setup_s": setup, "latency_after_end_s": lat, "session_s": sess, "file_s": fdt,
               "interim_msgs": ev.get("interim", 0), "final_msgs": len(ev.get("finals", [])),
               "live_retries": ev.get("retries", 0), "file_retries": fretries,
               "live_err": ev.get("err", ""), "file_err": ftext[5:] if ftext.startswith("ERR: ") else "",
               "live_tokens_in": u.get("promptTokenCount", 0), "live_tokens_out": u.get("responseTokenCount", 0),
               "file_tokens_in": fusage.get("total_input_tokens", 0), "file_tokens_out": fusage.get("total_output_tokens", 0),
               "ref_words": "", "live_wer_err": "", "file_wer_err": "",
               "live_text": ltext, "file_text": "" if ftext.startswith("ERR: ") else ftext, "reference_or_delivered": ref}
        if kind == "read":
            row["live_wer_err"], row["ref_words"] = wer(ref, ltext)
            row["file_wer_err"], _ = wer(ref, row["file_text"])
        rows.append(row); put(row)
        f = lambda x: f"{x:.2f}s" if x is not None else "—"
        head = f"── {kind} {wav.stem} ({row['audio_s']:.1f}s audio)  live +{f(lat)} after end, session {f(sess)}, setup {f(setup)}; file {f(fdt)}"
        if row["live_err"] or row["file_err"]:
            head += f"  ERR live={row['live_err']!r} file={row['file_err']!r}"
        say(head)
        if kind == "read":
            say(f"   REF       : {ref}\n   LIVE [{row['live_wer_err']}]: {ltext}\n   FILE [{row['file_wer_err']}]: {row['file_text']}")
        else:
            say(f"   DELIVERED : {ref}\n   LIVE      : {ltext}")
        time.sleep(1)

    say("\n══ summary")
    for kind in ("read", "real"):
        rs = [r for r in rows if r["set"] == kind]
        if not rs:
            continue
        ok = [r for r in rs if r["latency_after_end_s"] is not None and not r["live_err"]]
        lats = [r["latency_after_end_s"] for r in ok]
        sess = [r["session_s"] for r in ok]
        setups = [r["setup_s"] for r in rs if r["setup_s"] is not None]
        fts = [r["file_s"] for r in rs if not r["file_err"]]
        say(f"{kind}: {len(rs)} takes; live without error {len(ok)}; live errors {len(rs) - len(ok)}; file errors {sum(1 for r in rs if r['file_err'])}")
        for r in rs:
            if r["live_err"] or r["file_err"] or r["latency_after_end_s"] is None:
                say(f"   {r['take']}: live_err={r['live_err']!r} file_err={r['file_err']!r} live_retries={r['live_retries']} file_retries={r['file_retries']}")
        say(f"   live latency_after_end: median {pct(lats, .5):.2f}s  p90 {pct(lats, .9):.2f}s  min {min(lats, default=float('nan')):.2f}s  max {max(lats, default=float('nan')):.2f}s")
        say(f"   live session (connect -> final): median {pct(sess, .5):.2f}s; setup median {pct(setups, .5):.2f}s")
        say(f"   file request: median {pct(fts, .5):.2f}s  p90 {pct(fts, .9):.2f}s")
        if kind == "read":
            n = sum(r["ref_words"] for r in rs)
            say(f"   WER live {100 * sum(r['live_wer_err'] for r in rs) / n:.1f}%   file {100 * sum(r['file_wer_err'] for r in rs) / n:.1f}%   ({n} words)")
        else:
            exact = sum(r["live_text"] != r["reference_or_delivered"] for r in rs)
            norm = sum(words(r["live_text"]) != words(r["reference_or_delivered"]) for r in rs)
            e = sum(wer(r["reference_or_delivered"], r["live_text"])[0] for r in rs)
            n = sum(len(words(r["reference_or_delivered"])) for r in rs)
            say(f"   live text != delivered: {exact} exact, {norm} after lowercasing and dropping punctuation; "
                f"word distance live vs delivered {100 * e / n:.1f}% of {n} delivered words")
    tin = sum(r["live_tokens_in"] for r in rows); tout = sum(r["live_tokens_out"] for r in rows)
    fin = sum(r["file_tokens_in"] for r in rows); fout = sum(r["file_tokens_out"] for r in rows)
    if not tin:  # the live server sent no usageMetadata: 25 audio tokens/s (pricing page), output as the file model's
        tin = round(25 * sum(r["audio_s"] for r in rows)); tout = fout
        say("live usage: no usageMetadata from the server; estimated as 25 tokens per audio second in, "
            "file-mode output tokens out")
    say(f"tokens: live in {tin} out {tout} (≈${tin * 3.5e-6 + tout * 21e-6:.3f}); "
        f"file in {fin} out {fout} (≈${fin * 2e-6 + fout * 12e-6:.3f})")
    say(f"finished {time.strftime('%Y-%m-%d %H:%M:%S')}")


if __name__ == "__main__":
    main()
