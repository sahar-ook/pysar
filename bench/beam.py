#!/usr/bin/env python3
"""Greedy vs beam-search decoding in Parakeet, on your takes in
~/.pysar/audio/. Prints every take where the two differ and the time each
took. Local only; texts are printed, never written to the repo.

  ~/.pysar/venv/bin/python bench/beam.py [beam_size]
"""
import difflib, sys, time
from pathlib import Path
from parakeet_mlx import from_pretrained, DecodingConfig, Beam, Greedy

BEAM = int(sys.argv[1]) if len(sys.argv) > 1 else 5
model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
greedy = DecodingConfig(decoding=Greedy())
beam = DecodingConfig(decoding=Beam(beam_size=BEAM))

wavs = sorted((Path.home() / ".pysar" / "audio").glob("*.wav"))
model.transcribe(str(wavs[0]), decoding_config=greedy)      # warm up
tg = tb = 0.0
changed = 0
for wav in wavs:
    t0 = time.time(); g = model.transcribe(str(wav), decoding_config=greedy).text.strip(); t1 = time.time()
    b = model.transcribe(str(wav), decoding_config=beam).text.strip(); t2 = time.time()
    tg += t1 - t0; tb += t2 - t1
    if g != b:
        changed += 1
        print(f"── {wav.stem}  greedy {t1-t0:.2f}s / beam {t2-t1:.2f}s")
        A, B = g.split(), b.split()
        for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=A, b=B).get_opcodes():
            if op != "equal":
                print(f"   greedy: «{' '.join(A[max(0,i1-3):i2+3])}»\n   beam:   «{' '.join(B[max(0,j1-3):j2+3])}»")
        print()
print(f"{len(wavs)} takes, {changed} differ. Total time greedy {tg:.1f}s, beam {tb:.1f}s "
      f"(per take {tg/len(wavs):.2f}s vs {tb/len(wavs):.2f}s)")
