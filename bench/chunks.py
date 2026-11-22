#!/usr/bin/env python3
"""Would cutting a take at pauses while it is recorded change what Parakeet
hears? For every take in ~/.pysar/audio/ longer than MIN_SECONDS: cut at the
first pause of PAUSE_MS after at least CHUNK_S of audio, transcribe the pieces
separately, join them, and compare with the whole-file transcript. Also times
the last piece, which is all that would be left to transcribe after the key.

Local only. Texts are your dictation: printed, never written to the repo.

  python3 -I bench/chunks.py [chunk_s] [pause_ms]
"""
import array, difflib, io, json, sys, time, urllib.request, wave
from pathlib import Path

CHUNK_S = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
PAUSE_MS = int(sys.argv[2]) if len(sys.argv) > 2 else 400
MIN_SECONDS = 15
FRAME_MS = 50
PARAKEET = "http://127.0.0.1:50062/v1/audio/transcriptions"


def transcribe(pcm, rate):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm)
    b = "pysarchunks"
    body = b"".join([
        f'--{b}\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-1\r\n'.encode(),
        f'--{b}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'.encode(),
        f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        f'Content-Type: audio/wav\r\n\r\n'.encode() + buf.getvalue() + b"\r\n",
        f"--{b}--\r\n".encode()])
    req = urllib.request.Request(PARAKEET, data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=120) as r:
        text = json.loads(r.read())["text"].strip()
    return text, time.time() - t0


def cuts(samples, rate):
    """Sample offsets where a pause starts after at least CHUNK_S of audio."""
    n = int(rate * FRAME_MS / 1000)
    rms = []
    for i in range(0, len(samples) - n, n):
        f = samples[i:i + n]
        rms.append((sum(x * x for x in f) / n) ** 0.5)
    if not rms:
        return []
    floor = sorted(rms)[len(rms) // 10]          # quietest 10% = the room
    quiet = [r < max(floor * 2.5, 60) for r in rms]
    need = PAUSE_MS // FRAME_MS
    out, last, run = [], 0, 0
    for k, q in enumerate(quiet):
        run = run + 1 if q else 0
        start = (k - run + 1) * n
        if run == need and (start - last) >= CHUNK_S * rate:
            cut = start + (need * n) // 2           # middle of the pause
            out.append(cut); last = cut
    return out


def words(t):
    return [w.strip(".,!?:;«»\"'—-").lower() for w in t.split() if w.strip(".,!?:;«»\"'—-")]


total_w = total_diff = 0
rows = []
for wav in sorted((Path.home() / ".pysar" / "audio").glob("*.wav")):
    with wave.open(str(wav)) as w:
        rate, pcm = w.getframerate(), w.readframes(w.getnframes())
    seconds = len(pcm) / 2 / rate
    if seconds < MIN_SECONDS:
        continue
    samples = array.array("h", pcm)
    points = cuts(samples, rate)
    if not points:
        print(f"── {wav.stem} {seconds:.1f}s: no pause found, would not be cut\n")
        continue
    whole, t_whole = transcribe(pcm, rate)
    bounds = [0] + points + [len(samples)]
    pieces, t_last = [], 0
    for a, b in zip(bounds, bounds[1:]):
        text, t = transcribe(samples[a:b].tobytes(), rate)
        pieces.append(text); t_last = t
    joined = " ".join(pieces)
    A, B = words(whole), words(joined)
    sm = difflib.SequenceMatcher(a=A, b=B)
    diff = sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in sm.get_opcodes() if op != "equal")
    total_w += len(A); total_diff += diff
    tail = (len(samples) - bounds[-2]) / rate
    print(f"── {wav.stem} {seconds:.1f}s, {len(points)} cut(s), last piece {tail:.1f}s")
    print(f"   whole {t_whole:.2f}s -> after the key only {t_last:.2f}s; {diff} of {len(A)} words differ")
    if diff:
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op != "equal":
                print(f"   whole: «{' '.join(A[max(0,i1-3):i2+3])}»\n   cut:   «{' '.join(B[max(0,j1-3):j2+3])}»")
    print()
    rows.append((t_whole, t_last))

if rows:
    print(f"{len(rows)} takes cut. Words differing: {total_diff} of {total_w} ({100*total_diff/max(total_w,1):.1f}%).")
    print(f"Time left after the key: median {sorted(r[1] for r in rows)[len(rows)//2]:.2f}s "
          f"vs whole take {sorted(r[0] for r in rows)[len(rows)//2]:.2f}s")
