#!/usr/bin/env python3
"""Gemini 3.5 Transcribe with the dictionary as custom vocabulary, on a
read-aloud round (bench/reference2.txt) - the audio goes to Google.

  T    Gemini Transcribe alone (dictionary + uk-UA/en-US hints)
  T+F  its text through the formatter (prompt.md), as Pysar would

  python3 -I bench/transcribe.py 2026-10-20T16:20:14 [reference2.txt]   (first take of the round)
"""
import base64, json, re, sys, time, urllib.error, urllib.request
from pathlib import Path

RUN = Path.home() / ".pysar"
FIRST = sys.argv[1]
REF_FILE = sys.argv[2] if len(sys.argv) > 2 else "reference2.txt"
REF = [l.split("\t")[0] for l in (Path(__file__).parent / REF_FILE).read_text().splitlines()
       if l.strip() and not l.startswith("#")]
KEY = (RUN / "gemini-key").read_text().strip()
PROMPT = (RUN / "prompt.md").read_text()
TERMS = [l.strip() for l in (RUN / "dictionary.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]


def post(url, body, headers):
    # The transcribe model has a low per-minute limit: back off on 429.
    for attempt in range(6):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
                                                               headers=headers), timeout=90) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
            time.sleep(15 * (attempt + 1))


def transcribe(wav):
    body = {"model": "gemini-3.5-transcribe",
            "input": [{"type": "audio", "data": base64.b64encode(wav.read_bytes()).decode(), "mime_type": "audio/wav"}],
            "generation_config": {"transcription_config": {"custom_vocabulary": TERMS,
                                                           "language_codes": ["uk-UA", "en-US"]}}}
    t0 = time.time()
    r = post("https://generativelanguage.googleapis.com/v1beta/interactions", body,
             {"Content-Type": "application/json", "x-goog-api-key": KEY})
    text = " ".join(c.get("text", "") for st in r.get("steps", []) for c in st.get("content", []))
    return text.strip(), time.time() - t0, r.get("usage", {})


def fmt(text):
    body = {"model": "gemini-3.5-flash-lite", "temperature": 0.1, "reasoning_effort": "minimal",
            "messages": [{"role": "system", "content": PROMPT},
                         {"role": "user", "content": "Target application: Notes\nKnown names and terms: "
                          + ", ".join(TERMS) + "\n\n---\n\n" + text}]}
    t0 = time.time()
    r = post("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", body,
             {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    return r["choices"][0]["message"]["content"].strip(), time.time() - t0


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


rows = [json.loads(l) for l in open(RUN / "takes.jsonl")]
rows = [r for r in rows if r.get("outcome") == "ok" and r.get("transcript") and r["at"] >= FIRST][:len(REF)]
tot = {"T": 0, "TF": 0}; n_all = 0; times = []; audio_tokens = 0
for ref, r in zip(REF, rows):
    t, dt, usage = transcribe(RUN / r["audio"])
    f, _ = fmt(t)
    times.append(dt); audio_tokens += usage.get("total_input_tokens", 0)
    e1, n = wer(ref, t); e2, _ = wer(ref, f); tot["T"] += e1; tot["TF"] += e2; n_all += n
    print(f"── [{dt:.2f}s] REF: {ref}\n   T  [{e1}]: {t}\n   TF [{e2}]: {f}")
med = sorted(times)[len(times) // 2]
print(f"\nGemini Transcribe alone: {100*tot['T']/n_all:.1f}%   + formatter: {100*tot['TF']/n_all:.1f}%   "
      f"({n_all} words; median {med:.2f}s per take; {audio_tokens} input tokens)")
