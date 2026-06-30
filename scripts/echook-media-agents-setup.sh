#!/usr/bin/env bash
# Set up the echook media-control LaunchAgents.
#
# WHY: media-control (ungive/mediaremote-adapter) can pause/resume the macOS
# Now Playing session (incl. Chrome/YouTube/Telegram) on macOS 15.4+/26 -- but
# ONLY loads its framework when spawned by launchd (a direct child of a shell).
# When spawned under the echook hook's python it fails ("Failed to load
# framework"). So we register three on-demand LaunchAgents and the hook triggers
# them with `launchctl kickstart`; launchd runs media-control in a clean context.
#
#   com.echook.get   -> media-control get  (writes Now Playing JSON to /tmp/echook_np.json)
#   com.echook.pause -> media-control pause
#   com.echook.play  -> media-control play
#
# Idempotent. Agents live in ~/Library/LaunchAgents and auto-load on login.
# Re-run after reinstalling media-control or if `launchctl kickstart` says the
# label is not found. Requires: brew install media-control.
set -euo pipefail

MEDIA="$(command -v media-control || echo /opt/homebrew/bin/media-control)"
UID_="$(id -u)"
LA="$HOME/Library/LaunchAgents"
NP="/tmp/echook_np.json"
mkdir -p "$LA"

make_agent() {
  local label="$1"; shift
  local plist="$LA/$label.plist"
  local args_xml=""
  for a in "$@"; do args_xml+="    <string>$a</string>"$'\n'; done
  local stdout_key=""
  [ "$label" = "com.echook.get" ] && stdout_key="  <key>StandardOutPath</key><string>$NP</string>"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
$args_xml  </array>
$stdout_key
</dict></plist>
EOF
  launchctl bootout "gui/$UID_/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$plist"
  echo "registered: $label"
}

make_agent com.echook.get   "$MEDIA" get
make_agent com.echook.pause "$MEDIA" pause
make_agent com.echook.play  "$MEDIA" play

# Build the mic-busy probe -- the patch uses it to stay silent while you dictate
# (VoiceInk) or are on a call, without breaking the mic session.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIC_SRC="$SCRIPT_DIR/echook-mic-busy.swift"
MIC_BIN="$HOME/.claude/bin/echook-mic-busy"
if [ -f "$MIC_SRC" ]; then
  mkdir -p "$HOME/.claude/bin"
  if swiftc -O -o "$MIC_BIN" "$MIC_SRC" -framework CoreAudio -framework Foundation 2>/dev/null; then
    echo "built: echook-mic-busy"
  else
    echo "WARN: could not build echook-mic-busy (need Xcode Command Line Tools / swiftc)"
  fi
else
  echo "WARN: $MIC_SRC not found next to this script; mic-busy detection disabled"
fi

echo
echo "done. media-control: $MEDIA"
echo "test:  launchctl kickstart -k gui/$UID_/com.echook.pause   (should pause your music)"
