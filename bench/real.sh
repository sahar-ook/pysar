#!/usr/bin/env bash
# Runs your real takes through one formatter: each WAV kept in ~/.pysar/audio/
# goes through Parakeet once (cached), then through the formatter with the same
# context Pysar sends. Prints raw → formatted and wall time, and appends the
# times to ~/.pysar/bench/<label>.tsv.
#
#   bench/real.sh <label> <endpoint> <model> [key-file] [extra-json] [limit]
#
#   bench/real.sh glm    https://api.z.ai/api/paas/v4/chat/completions glm-4.7 ~/.pysar/api-key '{"thinking":{"type":"disabled"}}'
#   bench/real.sh gemini https://generativelanguage.googleapis.com/v1beta/openai/chat/completions gemini-3.1-flash-lite ~/.pysar/gemini-key '{"reasoning_effort":"minimal"}'
#
# The texts are your dictation, so they stay in ~/.pysar/bench/, never in the repo.
set -uo pipefail
LABEL=$1; ENDPOINT=$2; MODEL=$3; KEYFILE=${4:-}; EXTRA=${5:-'{}'}; LIMIT=${6:-1000}
RUN="$HOME/.pysar"; OUT="$RUN/bench"; mkdir -p "$OUT/raw"
PROMPT="$RUN/prompt.md"; DICT="$RUN/dictionary.txt"
PARAKEET="http://127.0.0.1:50062/v1/audio/transcriptions"
TERMS=$(grep -v '^#' "$DICT" 2>/dev/null | grep -v '^$' | tr '\n' ',' | sed 's/,$//')

RC=$(mktemp); trap 'rm -f "$RC"' EXIT
if [ -n "$KEYFILE" ] && [ -s "$KEYFILE" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$KEYFILE")" > "$RC"
else
  : > "$RC"
fi

echo "════════ $LABEL  ($MODEL) ════════"
n=0
for wav in "$RUN"/audio/*.wav; do
  [ "$n" -ge "$LIMIT" ] && break
  name=$(basename "$wav" .wav)
  raw="$OUT/raw/$name.txt"
  if [ ! -s "$raw" ]; then
    curl -s -m 60 "$PARAKEET" -F "file=@$wav" -F model=whisper-1 -F response_format=json \
      | jq -r '.text // empty' > "$raw"
  fi
  [ -s "$raw" ] || continue
  n=$((n + 1))

  # Same context block as pysar.lua's context(): the app the take went to.
  at=$(echo "$name" | sed -E 's/_/T/; s/T([0-9]{2})-([0-9]{2})-([0-9]{2})$/T\1:\2:\3/')
  app=$(jq -r --arg at "$at" 'select(.at == $at) | .app // empty' "$RUN/takes.jsonl" 2>/dev/null | head -1)
  ctx="Target application: ${app:-Notes}
Known names and terms: $TERMS

---

"
  body=$(jq -n --arg m "$MODEL" --rawfile p "$PROMPT" --arg u "$ctx$(cat "$raw")" --argjson x "$EXTRA" \
    '{model:$m, temperature:0.1, messages:[{role:"system",content:$p},{role:"user",content:$u}]} + $x')
  start=$(python3 -c 'import time;print(time.time())')
  resp=$(curl -s --max-time 60 -K "$RC" -H 'content-type: application/json' -d "$body" "$ENDPOINT")
  secs=$(python3 -c "import time;print('%.2f' % (time.time()-$start))")
  out=$(echo "$resp" | jq -r '.choices[0].message.content // ("ERR: " + (.error.message // .error // . | tostring))' 2>/dev/null \
        || echo "ERR: $(echo "$resp" | head -c 200)")
  printf '%s\t%s\t%s\n' "$name" "$secs" "$(echo "$resp" | jq -c '.usage // {}' 2>/dev/null)" >> "$OUT/$LABEL.tsv"

  echo; echo "── $name  [$secs s]"
  echo "raw: $(cat "$raw")"
  echo "out: $out"
done
echo; echo "$n takes. Times: $OUT/$LABEL.tsv"
