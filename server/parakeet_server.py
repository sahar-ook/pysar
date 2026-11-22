"""Local speech-to-text server wrapping NVIDIA Parakeet TDT 0.6B v3 via MLX.

Speaks the same /v1/audio/transcriptions dialect the WhisperKit server does,
so the Hammerspoon side switches engines by changing one port number and
nothing else. Two things Parakeet does not give us are synthesised here:

- `language`: derived from the script of the output. Parakeet v3 detects the
  language internally and does not report it; for our purposes Cyrillic means
  Ukrainian and anything else means English.
- `no_speech_prob`: 1 - per-sentence confidence. The client drops a take when
  every segment scores above 0.6, which is the same guard it used with Whisper.

The model loads once at startup (~1 s warm, longer on first run). The server is
deliberately single-threaded: MLX binds its compute stream to the thread that
created the model, and a request handled on any other thread fails with
"There is no Stream(cpu, 1) in current thread". Requests queue instead, which is
fine - the client sends one at a time and each takes well under a second.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = os.environ.get("PYSAR_PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")

model = None
lock = threading.Lock()

CYRILLIC = re.compile(r"[Ѐ-ӿ]")
LATIN = re.compile(r"[A-Za-z]")


def guess_language(text: str) -> str:
    return "uk" if len(CYRILLIC.findall(text)) > len(LATIN.findall(text)) else "en"


def parse_multipart(body: bytes, content_type: str) -> dict:
    """Minimal multipart/form-data parser. Returns {name: bytes}; file parts
    keep their bytes, text parts are decoded by the caller."""
    m = re.search(r"boundary=([^;]+)", content_type)
    if not m:
        return {}
    boundary = m.group(1).strip().strip('"').encode()
    fields = {}
    for part in body.split(b"--" + boundary):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        disp = re.search(rb'name="([^"]+)"', head)
        if disp:
            fields[disp.group(1).decode()] = data
    return fields


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep launchd logs quiet
        sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), fmt % args))

    def _json(self, code: int, payload: dict):
        raw = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._json(200, {"ok": True, "model": MODEL, "engine": "parakeet-mlx"})

    def do_POST(self):
        if self.path != "/v1/audio/transcriptions":
            return self._json(404, {"error": True, "reason": "unknown path"})
        length = int(self.headers.get("Content-Length", 0))
        fields = parse_multipart(self.rfile.read(length), self.headers.get("Content-Type", ""))
        audio = fields.get("file")
        if not audio:
            return self._json(400, {"error": True, "reason": "no file field"})
        fmt = fields.get("response_format", b"json").decode(errors="ignore")

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(audio)
            path = tmp.name
        try:
            t0 = time.time()
            with lock:
                result = model.transcribe(path)
            elapsed = time.time() - t0
        except Exception as exc:  # surface the reason, never a bare 500
            return self._json(500, {"error": True, "reason": str(exc)})
        finally:
            os.unlink(path)

        text = result.text.strip()
        language = guess_language(text)
        self.log_message("transcribed %.1fs of audio in %.2fs -> %d chars [%s]",
                         result.sentences[-1].end if result.sentences else 0.0,
                         elapsed, len(text), language)

        if fmt == "text":
            raw = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            return self.wfile.write(raw)

        payload = {"text": text, "language": language}
        if fmt == "verbose_json":
            payload["duration"] = result.sentences[-1].end if result.sentences else 0.0
            payload["segments"] = [
                {
                    "id": i,
                    "start": s.start,
                    "end": s.end,
                    "text": s.text,
                    "no_speech_prob": round(1.0 - float(s.confidence), 4),
                }
                for i, s in enumerate(result.sentences)
            ]
        self._json(200, payload)


def main():
    global model
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=50062)
    args = ap.parse_args()

    from parakeet_mlx import from_pretrained
    t0 = time.time()
    model = from_pretrained(MODEL)
    sys.stderr.write("[parakeet] %s loaded in %.2fs\n" % (MODEL, time.time() - t0))

    srv = HTTPServer((args.host, args.port), Handler)
    sys.stderr.write("[parakeet] listening on http://%s:%d\n" % (args.host, args.port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
