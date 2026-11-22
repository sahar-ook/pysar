#!/usr/bin/env bash
# Runs every sample through one formatter and prints output + wall time.
#
#   bench/run.sh <label> <endpoint> <model> [key-file] [extra-json]
#
#   bench/run.sh glm    https://api.z.ai/api/paas/v4/chat/completions glm-4.7 ~/.pysar/api-key '{"thinking":{"type":"disabled"}}'
#   bench/run.sh gemini https://generativelanguage.googleapis.com/v1beta/openai/chat/completions gemini-3.1-flash-lite ~/.pysar/gemini-key '{"reasoning_effort":"minimal"}'
#   bench/run.sh qwen  http://127.0.0.1:11434/v1/chat/completions   qwen3:14b "" '{"think":false}'
set -uo pipefail
LABEL=$1; ENDPOINT=$2; MODEL=$3; KEYFILE=${4:-}; EXTRA=${5:-'{}'}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="$HOME/.pysar/prompt.md"; DICT="$HOME/.pysar/dictionary.txt"
TERMS=$(grep -v '^#' "$DICT" 2>/dev/null | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
CTX="Target application: Notes
Known names and terms: $TERMS

---
"
RC=$(mktemp); trap 'rm -f "$RC"' EXIT
if [ -n "$KEYFILE" ] && [ -s "$KEYFILE" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$KEYFILE")" > "$RC"
else
  : > "$RC"
fi
echo "════════ $LABEL  ($MODEL @ ${ENDPOINT%%/v1*}) ════════"
for f in "$DIR"/samples/*.txt; do
  name=$(basename "$f" .txt)
  body=$(jq -n --arg m "$MODEL" --rawfile p "$PROMPT" --arg u "$CTX$(cat "$f")" --argjson x "$EXTRA" \
    '{model:$m, temperature:0.1, messages:[{role:"system",content:$p},{role:"user",content:$u}]} + $x')
  start=$(python3 -c 'import time;print(time.time())')
  out=$(curl -s --max-time 180 -K "$RC" -H 'content-type: application/json' -d "$body" "$ENDPOINT")
  secs=$(python3 -c "import time;print('%.1f' % (time.time()-$start))")
  echo; echo "── $name  [$secs s]"
  echo "$out" | jq -r '.choices[0].message.content // ("ERR: " + (.error.message // .error // . | tostring))' 2>/dev/null || echo "$out" | head -c 300
done
