#!/usr/bin/env bash
# Stores the Gemini API key (aistudio.google.com -> Get API key) in
# ~/.pysar/gemini-key and proves it works with one short formatting request
# and a Live setup (no audio). The key is read blind, never echoed, and reaches
# curl through a config file.
#
#   ./set-gemini-key.sh          # the paid key, ~/.pysar/gemini-key
#   ./set-gemini-key.sh --free   # a key from a project WITHOUT billing,
#                                # ~/.pysar/gemini-key-free; Pysar tries it first
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HOME/.pysar"
KEY_FILE="$DIR/gemini-key"
if [ "${1:-}" = "--free" ]; then KEY_FILE="$DIR/gemini-key-free"; shift; fi
MODEL="${1:-gemini-3.5-flash-lite}"
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

mkdir -p "$DIR"; chmod 700 "$DIR"

printf 'Paste the Gemini API key, then press Return (nothing will appear): '
KEY=""
IFS= read -rs KEY < /dev/tty || true
echo
[ -n "$KEY" ] || { echo "nothing entered, aborting"; exit 1; }

# A Gemini key is one token: the old AIza… form (~39 characters) or the newer
# AQ.… form (~55). Anything with spaces or far longer is a bad paste.
LEN=${#KEY}
if printf '%s' "$KEY" | grep -q '[[:space:]]' || [ "$LEN" -lt 30 ] || [ "$LEN" -gt 120 ]; then
  echo "That does not look like a Gemini key (length $LEN, expected 39-60, one word)."
  echo "Nothing was stored. Copy only the key and run this again."
  unset KEY
  exit 1
fi

umask 077
printf '%s' "$KEY" > "$KEY_FILE"
unset KEY
echo "stored in $KEY_FILE"

RC="$DIR/.probe.curlrc"
trap 'rm -f "$RC" "$DIR/.probe.out"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$KEY_FILE")" > "$RC"

BODY=$(jq -n --arg m "$MODEL" \
  '{model:$m, reasoning_effort:"minimal", temperature:0.1,
    messages:[{role:"user",content:"Поверни цей текст без змін: Перевірка ключа."}]}')
CODE=$(curl -s -o "$DIR/.probe.out" -w '%{http_code}' --max-time 60 \
  -K "$RC" -H 'content-type: application/json' -d "$BODY" "$ENDPOINT") || CODE="timeout"

echo
if [ "$CODE" = "200" ]; then
  echo "OK — $MODEL answered: $(jq -r '.choices[0].message.content' "$DIR/.probe.out")"
else
  echo "HTTP $CODE"
  jq -r '.[0].error.message // .error.message // .' "$DIR/.probe.out" 2>/dev/null || cat "$DIR/.probe.out"
fi
PY="$DIR/venv/bin/python"; [ -x "$PY" ] || PY=python3
"$PY" "$REPO/server/live_server.py" --probe "$KEY_FILE" || true
echo "You can close this tab."
