#!/usr/bin/env bash
set -euo pipefail
LABEL="com.pysar.server"
for L in "$LABEL" com.pysar.parakeet com.pysar.live; do
  launchctl bootout "gui/$UID/$L" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$L.plist"
done
rm -f "$HOME/.hammerspoon/pysar.lua"
echo "Removed. Delete the require(\"pysar\") line from ~/.hammerspoon/init.lua yourself."
echo "Recordings, logs and the API key are in ~/.pysar - delete it if you are done."
