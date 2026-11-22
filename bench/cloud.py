#!/usr/bin/env python3
"""Compares the live pipeline with Gemini hearing the audio itself, on your
own takes in ~/.pysar/audio/.

  A  Parakeet (local) -> Gemini formats the text        (what Pysar does now)
  B  Gemini gets the WAV and transcribes + formats it   (voice goes to Google)

Same prompt.md, dictionary and context block for both. Results, which hold
your dictation, go to ~/.pysar/bench/cloud.jsonl and cloud.txt - never the repo.

  python3 -I bench/cloud.py [limit] [model]
"""
import base64, json, sys, time, urllib.request
from pathlib import Path

RUN = Path.home() / ".pysar"
OUT = RUN / "bench"; (OUT / "raw").mkdir(parents=True, exist_ok=True)
LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
MODEL = sys.argv[2] if len(sys.argv) > 2 else "gemini-3.5-flash-lite"
CHAT = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
PARAKEET = "http://127.0.0.1:50062/v1/audio/transcriptions"

KEY = (RUN / "gemini-key").read_text().strip()
PROMPT = (RUN / "prompt.md").read_text()
TERMS = ",".join(l.strip() for l in (RUN / "dictionary.txt").read_text().splitlines()
                 if l.strip() and not l.startswith("#"))
APPS = {}
for line in (RUN / "takes.jsonl").read_text().splitlines():
    try:
        r = json.loads(line); APPS[r["at"]] = r.get("app")
    except Exception:
        pass

AUDIO_NOTE = ("There is no transcript text: the dictation is the attached audio. "
              "Transcribe exactly what is said - Ukrainian with English words and "
              "terms mixed in; the speaker never speaks Russian - then apply every "
              "rule above to it and return only the result.")


def post(url, body, headers):
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def parakeet(wav):
    cache = OUT / "raw" / (wav.stem + ".txt")
    if cache.exists() and cache.read_text().strip():
        return cache.read_text().strip()
    boundary = "pysarbench"
    parts = [
        f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-1\r\n'.encode(),
        f'--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'.encode(),
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        f'Content-Type: audio/wav\r\n\r\n'.encode() + wav.read_bytes() + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ]
    text = json.loads(post(PARAKEET, b"".join(parts),
                           {"Content-Type": f"multipart/form-data; boundary={boundary}"}))["text"].strip()
    cache.write_text(text)
    return text


def gemini(user_content):
    body = json.dumps({
        "model": MODEL, "temperature": 0.1, "reasoning_effort": "minimal",
        "messages": [{"role": "system", "content": PROMPT},
                     {"role": "user", "content": user_content}],
    }).encode()
    t0 = time.time()
    try:
        r = json.loads(post(CHAT, body, {"Content-Type": "application/json",
                                         "Authorization": f"Bearer {KEY}"}))
        return r["choices"][0]["message"]["content"].strip(), time.time() - t0
    except Exception as e:  # keep going; the error is part of the result
        return f"ERR: {e}", time.time() - t0


def context(stem):
    at = stem.replace("_", "T", 1)
    at = at[:13] + ":" + at[14:16] + ":" + at[17:19]
    return (f"Target application: {APPS.get(at) or 'Notes'}\n"
            f"Known names and terms: {TERMS}\n\n---\n\n")


results = []
wavs = sorted((RUN / "audio").glob("*.wav"))[:LIMIT]
with open(OUT / "cloud.jsonl", "w") as jl, open(OUT / "cloud.txt", "w") as txt:
    for wav in wavs:
        try:
            raw = parakeet(wav)
        except Exception as e:
            raw = f"ERR: {e}"
        a, ta = gemini(context(wav.stem) + raw) if not raw.startswith("ERR") else (raw, 0)
        b64 = base64.b64encode(wav.read_bytes()).decode()
        b, tb = gemini([{"type": "text", "text": context(wav.stem) + AUDIO_NOTE},
                        {"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}}])
        row = {"take": wav.stem, "parakeet": raw, "A": a, "A_s": round(ta, 2), "B": b, "B_s": round(tb, 2)}
        jl.write(json.dumps(row, ensure_ascii=False) + "\n"); jl.flush()
        txt.write(f"── {wav.stem}\nPK: {raw}\nA [{ta:.2f}s]: {a}\nB [{tb:.2f}s]: {b}\n\n"); txt.flush()
        results.append(row)
        time.sleep(0.3)

ok = [r for r in results if not r["A"].startswith("ERR") and not r["B"].startswith("ERR")]
med = lambda xs: sorted(xs)[len(xs) // 2] if xs else 0
print(f"{len(results)} takes, {len(ok)} without errors")
print(f"A (Parakeet + Gemini text): median {med([r['A_s'] for r in ok]):.2f}s format only")
print(f"B (Gemini audio):           median {med([r['B_s'] for r in ok]):.2f}s end to end")
print(f"identical outputs: {sum(r['A'] == r['B'] for r in ok)}")
