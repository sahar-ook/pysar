#!/usr/bin/env python3
"""Read-aloud test against bench/reference.txt: which recogniser feeds the
formatter best? For each reference sentence and its take:

  A  Parakeet -> Gemini            (what Pysar does now)
  B  WhisperKit -> Gemini
  C  both -> Gemini, told to pick the most plausible reading

Word error rate against the reference, plus recognition time. Only text goes
to Gemini, as in normal use. Texts are printed, never written to the repo.

  python3 -I bench/ensemble.py <first-take-stem> [count]
  e.g.  python3 -I bench/ensemble.py 2026-10-20_15-21-18 15
"""
import io, json, re, sys, time, urllib.request
from pathlib import Path

RUN = Path.home() / ".pysar"
REF = [l.split("\t")[0] for l in (Path(__file__).parent / "reference.txt").read_text().splitlines()
       if l.strip() and not l.startswith("#")]
FIRST, COUNT = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else len(REF)
KEY = (RUN / "gemini-key").read_text().strip()
PROMPT = (RUN / "prompt.md").read_text()
TERMS = ",".join(l.strip() for l in (RUN / "dictionary.txt").read_text().splitlines()
                 if l.strip() and not l.startswith("#"))
CTX = f"Target application: Notes\nKnown names and terms: {TERMS}\n\n---\n\n"
BOTH = ("Two speech recognisers heard the same dictation. The first (Parakeet) is "
        "usually right about Ukrainian words; the second (Whisper) is usually right "
        "about English words, names and short words, but sometimes writes Ukrainian "
        "as Russian. Work out what the speaker most plausibly said, using both, and "
        "apply every rule above to that. Return only the result.\n\n")


def post(url, body, headers):
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=90) as r:
        return r.read()


def stt(port, wav, prompt=None):
    b = "pysarens"
    fields = [("model", "whisper-1"), ("response_format", "json")] + ([("prompt", prompt)] if prompt else [])
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields]
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
                 f'Content-Type: audio/wav\r\n\r\n'.encode() + wav.read_bytes() + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    t0 = time.time()
    text = json.loads(post(f"http://127.0.0.1:{port}/v1/audio/transcriptions", b"".join(parts),
                           {"Content-Type": f"multipart/form-data; boundary={b}"}))["text"].strip()
    return text, time.time() - t0


def gemini(user, system=PROMPT):
    body = json.dumps({"model": "gemini-3.5-flash-lite", "temperature": 0.1, "reasoning_effort": "minimal",
                       "messages": [{"role": "system", "content": system},
                                    {"role": "user", "content": user}]}).encode()
    t0 = time.time()
    r = json.loads(post("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", body,
                        {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"}))
    return r["choices"][0]["message"]["content"].strip(), time.time() - t0


def words(t):
    t = t.lower().replace("ё", "е").replace("’", "'")
    return [w for w in re.split(r"[^\w']+", t) if w]


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)


wavs = sorted(p for p in (RUN / "audio").glob("*.wav") if p.stem >= FIRST)[:COUNT]
tot = {"A": [0, 0], "B": [0, 0], "C": [0, 0]}
times = {"pk": [], "wk": []}
for ref, wav in zip(REF, wavs):
    pk, tpk = stt(50062, wav)
    wk, twk = stt(50060, wav, TERMS)
    times["pk"].append(tpk); times["wk"].append(twk)
    A, _ = gemini(CTX + pk)
    B, _ = gemini(CTX + wk)
    C, _ = gemini(CTX + BOTH + "1 (Parakeet): " + pk + "\n2 (Whisper): " + wk)
    print(f"── {wav.stem}\n   REF: {ref}\n   PK : {pk}\n   WK : {wk}")
    for k, v in (("A", A), ("B", B), ("C", C)):
        e, n = wer(ref, v); tot[k][0] += e; tot[k][1] += n
        print(f"   {k} [{e} err]: {v}")
    print()
for k, label in (("A", "Parakeet -> Gemini (now)"), ("B", "WhisperKit -> Gemini"), ("C", "both -> Gemini")):
    e, n = tot[k]
    print(f"{label:28s} WER {100 * e / n:.1f}%  ({e} of {n} words)")
med = lambda xs: sorted(xs)[len(xs) // 2]
print(f"recognition median: Parakeet {med(times['pk']):.2f}s, WhisperKit {med(times['wk']):.2f}s")
