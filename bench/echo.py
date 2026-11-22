#!/usr/bin/env python3
"""Does quoting the text before the caret make Gemini repeat its tail? Replays
the second read-aloud round (bench/reference2.txt, the last 20 takes of a run)
with the field text simulated as the reference sentences dictated before, in
three variants of the context block:

  A  quote as Pysar sends it now
  B  quote with a stronger "never repeat any of it"
  C  no quote (Pysar joins the text locally anyway)

Counts takes whose output opens with a piece of the quoted text, and WER.
Only text goes to Gemini. Nothing is written to the repo.

  python3 -I bench/echo.py 2026-10-20T15:48:50   (the first take of the round)
"""
import json, re, sys, time, urllib.request
from pathlib import Path

RUN = Path.home() / ".pysar"
REF = [l.split("\t")[0] for l in (Path(__file__).parent / "reference2.txt").read_text().splitlines()
       if l.strip() and not l.startswith("#")]
FIRST = sys.argv[1]
KEY = (RUN / "gemini-key").read_text().strip()
PROMPT = (RUN / "prompt.md").read_text()
TERMS = ", ".join(l.strip() for l in (RUN / "dictionary.txt").read_text().splitlines()
                  if l.strip() and not l.startswith("#"))
STYLE = ("Style: casual - normal capitals and commas; the message does not end with a full stop. "
         "A question mark or an exclamation mark at the end stays")
BOTH = ("Two speech recognisers heard the same dictation. The first (Parakeet) is "
        "usually right about Ukrainian words; the second (Whisper) is usually right "
        "about English words, names and short words, but sometimes writes Ukrainian "
        "as Russian. Work out what the speaker most plausibly said, using both, and "
        "apply every rule above to that. Return only the result.\n\n")
QUOTE = {
    "A": "Text already in the field, ending at the caret (continue it, do not repeat it):\n«{}»",
    "B": ("Text already in the field before the caret. It is context only: never output any of it, "
          "not its last word and not a piece of a word. Your output starts with what the speaker "
          "said in this take:\n«{}»"),
    "C": None,
}


def post(url, body, headers):
    with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=90) as r:
        return r.read()


def whisper(wav):
    b = "pysarecho"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
             for k, v in (("model", "whisper-1"), ("response_format", "json"), ("prompt", TERMS))]
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
                 f'Content-Type: audio/wav\r\n\r\n'.encode() + wav.read_bytes() + b"\r\n")
    parts.append(f"--{b}--\r\n".encode())
    return json.loads(post("http://127.0.0.1:50060/v1/audio/transcriptions", b"".join(parts),
                           {"Content-Type": f"multipart/form-data; boundary={b}"}))["text"].strip()


def gemini(user):
    body = json.dumps({"model": "gemini-3.5-flash-lite", "temperature": 0.1, "reasoning_effort": "minimal",
                       "messages": [{"role": "system", "content": PROMPT},
                                    {"role": "user", "content": user}]}).encode()
    r = json.loads(post("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", body,
                        {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"}))
    return r["choices"][0]["message"]["content"].strip()


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


def echoed(out, before):
    head = out.split()[0] if out.split() else ""
    head = head.strip(".,!?:;«»")
    return len(head) >= 2 and before.rstrip(".,!?:; ").endswith(head) and not REF_START.lower().startswith(head.lower())


rows = [json.loads(l) for l in open(RUN / "takes.jsonl")]
rows = [r for r in rows if r.get("outcome") == "ok" and r.get("transcript") and r["at"] >= FIRST][:20]
score = {k: [0, 0, 0] for k in QUOTE}
for i, (ref, r) in enumerate(zip(REF, rows)):
    raw = (RUN / "transcripts" / f"{r['transcript']}.raw.txt")
    pk = raw.read_text().strip() if raw.exists() else (RUN / "transcripts" / f"{r['transcript']}.txt").read_text().strip()
    wk = whisper(RUN / r["audio"])
    before = " ".join(REF[:i])[-400:]
    REF_START = ref
    print(f"── {i+1}: {ref}")
    for k, q in QUOTE.items():
        ctx = ["Target application: Claude", STYLE, "Known names and terms: " + TERMS]
        if q and before:
            ctx.append(q.format(before))
        out = gemini("\n".join(ctx) + "\n\n---\n\n" + BOTH + "1 (Parakeet): " + pk + "\n2 (Whisper): " + wk)
        e, n = wer(ref, out)
        ech = bool(before) and echoed(out, before)
        score[k][0] += e; score[k][1] += n; score[k][2] += ech
        print(f"   {k}{' ECHO' if ech else ''} [{e}]: {out}")
for k in QUOTE:
    e, n, ech = score[k]
    print(f"{k}: WER {100*e/n:.1f}%  echoes {ech}")
