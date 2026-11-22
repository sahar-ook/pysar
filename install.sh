#!/usr/bin/env bash
# Pysar — installer. Idempotent; safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.pysar.server"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HS_DIR="$HOME/.hammerspoon"
# Models go to ~/.pysar/models unless PYSAR_MODEL_DIR points elsewhere.
if [ -n "${PYSAR_MODEL_DIR:-}" ]; then MODEL_DIR="$PYSAR_MODEL_DIR"
else MODEL_DIR="$HOME/.pysar/models"; fi
VARIANT="large-v3-v20240930_626MB"   # quantised large-v3; the full one is 2.9 GB and 4x slower
MODEL="$MODEL_DIR/argmaxinc/whisperkit-coreml/openai_whisper-$VARIANT"
# whisperkit-cli 1.1 saves downloads one level deeper, under models/.
NESTED="$MODEL_DIR/models/argmaxinc/whisperkit-coreml/openai_whisper-$VARIANT"
[ -d "$MODEL" ] || [ ! -d "$NESTED" ] || MODEL="$NESTED"

say() { printf '\033[1m›\033[0m %s\n' "$*"; }

# --- dependencies -------------------------------------------------------------
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

for f in whisperkit-cli sox ffmpeg uv; do
  command -v "$f" >/dev/null || { say "installing $f"; brew install "$f"; }
done
[ -d /Applications/Hammerspoon.app ] || { say "installing Hammerspoon"; brew install --cask hammerspoon; }

WHISPERKIT="$(command -v whisperkit-cli)"
SOX="$(command -v sox)"

# --- model --------------------------------------------------------------------
if [ ! -d "$MODEL" ]; then
  say "downloading whisper large-v3 (~630 MB) into $MODEL_DIR"
  mkdir -p "$MODEL_DIR"
  "$WHISPERKIT" transcribe --model "$VARIANT" --download-model-path "$MODEL_DIR" \
    --audio-path /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 || true
  [ -d "$MODEL" ] || MODEL="$NESTED"
  [ -d "$MODEL" ] || { echo "model download failed; set PYSAR_MODEL_DIR and retry"; exit 1; }
fi
say "model: $MODEL"

# --- background server --------------------------------------------------------
mkdir -p "$HOME/.pysar" "$HOME/Library/LaunchAgents"
chmod 700 "$HOME/.pysar"
ln -sfn "$REPO/prompt.md" "$HOME/.pysar/prompt.md"
[ -f "$HOME/.pysar/dictionary.txt" ] || cp "$REPO/dictionary.example.txt" "$HOME/.pysar/dictionary.txt"
sed -e "s|__WHISPERKIT__|$WHISPERKIT|g" \
    -e "s|__MODEL_PATH__|$MODEL|g" \
    -e "s|__HOME__|$HOME|g" \
    "$REPO/launchd/$LABEL.plist" > "$AGENT"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# bootstrap fails if the previous job has not fully exited yet
for _ in $(seq 1 20); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$UID" "$AGENT"
say "launch agent loaded ($LABEL)"

# --- formatter API key --------------------------------------------------------
# One Gemini key serves both the live transcription and the formatter (Gemini
# 3.5 Flash-Lite, only on takes that need it); it comes from aistudio.google.com
# (Get API key). ./set-gemini-key.sh stores it later and checks it works.
KEY_FILE="$HOME/.pysar/gemini-key"
if [ ! -s "$KEY_FILE" ] && [ -t 0 ]; then
  echo
  echo "Formatting pass (optional). Paste a Gemini API key to enable it, or press"
  echo "Return to skip - dictation works either way, just without the structuring."
  printf "  Gemini API key: "
  read -rs KEY
  echo
  if [ -n "$KEY" ]; then
    printf '%s' "$KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    say "key stored in $KEY_FILE"
  else
    say "skipped - add it later and the formatter turns itself on"
  fi
  unset KEY
fi

# --- Parakeet v3 (offline speech-to-text) -------------------------------------
# Lives in its own venv so launchd can run it. The weights (~600 MB) are pulled
# here in the foreground: the agent runs with HF_HUB_OFFLINE=1 and would never
# fetch them itself.
VENV="$HOME/.pysar/venv"
if [ ! -x "$VENV/bin/python" ]; then
  say "creating $VENV"
  uv venv "$VENV" --python 3.12 >/dev/null
fi
uv pip install --python "$VENV/bin/python" --quiet "parakeet-mlx>=0.5.2"
say "downloading Parakeet v3 weights if missing"
PATH="/opt/homebrew/bin:$PATH" "$VENV/bin/python" -c \
  "from parakeet_mlx import from_pretrained; from_pretrained('mlx-community/parakeet-tdt-0.6b-v3')" >/dev/null 2>&1 \
  || { echo "Parakeet weights download failed - check the network and re-run"; exit 1; }

PK_LABEL="com.pysar.parakeet"
PK_AGENT="$HOME/Library/LaunchAgents/$PK_LABEL.plist"
sed -e "s|__VENV__|$VENV|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
    "$REPO/launchd/$PK_LABEL.plist" > "$PK_AGENT"
launchctl bootout "gui/$UID/$PK_LABEL" 2>/dev/null || true
for _ in $(seq 1 20); do
  launchctl print "gui/$UID/$PK_LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$UID" "$PK_AGENT"
say "launch agent loaded ($PK_LABEL)"

# --- Gemini 3.5 Transcribe Live (main speech-to-text) -------------------------
# Streams each take to Google while the key is held; Parakeet above is the
# offline fallback. Standard library only, so the Parakeet venv's Python runs
# it. Without a key in ~/.pysar/gemini-key every take goes to Parakeet.
LV_LABEL="com.pysar.live"
LV_AGENT="$HOME/Library/LaunchAgents/$LV_LABEL.plist"
sed -e "s|__VENV__|$VENV|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
    "$REPO/launchd/$LV_LABEL.plist" > "$LV_AGENT"
launchctl bootout "gui/$UID/$LV_LABEL" 2>/dev/null || true
for _ in $(seq 1 20); do
  launchctl print "gui/$UID/$LV_LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$UID" "$LV_AGENT"
say "launch agent loaded ($LV_LABEL)"

# --- Hammerspoon --------------------------------------------------------------
mkdir -p "$HS_DIR"
ln -sfn "$REPO/hammerspoon/pysar.lua" "$HS_DIR/pysar.lua"

if ! grep -q "pysar" "$HS_DIR/init.lua" 2>/dev/null; then
  cat >> "$HS_DIR/init.lua" <<'LUA'

-- Pysar
require("pysar").start({
  sox = "__SOX__",
})
LUA
  sed -i '' "s|__SOX__|$SOX|" "$HS_DIR/init.lua"
  say "added Pysar to $HS_DIR/init.lua"
else
  say "$HS_DIR/init.lua already references Pysar — left alone"
fi

# --- start with the machine ---------------------------------------------------
# The transcription server has a launch agent; Hammerspoon needs a login item,
# or the whole tool quietly stops existing after a reboot.
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -qi hammerspoon; then
  osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Hammerspoon.app", hidden:true}' >/dev/null 2>&1 \
    && say "Hammerspoon added to login items" \
    || say "could not add the login item - add Hammerspoon by hand in System Settings > General > Login Items"
fi

# --- wait for the model to warm up -------------------------------------------
say "waiting for the transcription servers…"
for PORT in 50062 50060; do
  for _ in $(seq 1 90); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    sleep 1
  done
done

cat <<'DONE'

Installed. Two permissions still have to be granted by hand:

  System Settings > Privacy & Security > Microphone     > Hammerspoon
  System Settings > Privacy & Security > Accessibility  > Hammerspoon

Then open Hammerspoon and hit Reload Config.

  Right Cmd         press to start, press again to stop
  Opt-Shift-Space   toggle on/off for long dictation

DONE
