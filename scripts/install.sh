#!/usr/bin/env bash
# Builds Needs You.app, signs it with your Apple Development identity (a
# stable signature keeps the microphone grant across rebuilds), installs it to
# ~/Applications, links the CLI into ~/.local/bin and downloads the local speech
# models once.
#
#   scripts/install.sh                 build, install, check the models
#   SKIP_MODELS=1 scripts/install.sh   skip the local model check/download
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/Needs You.app"
OUT="$app" scripts/bundle.sh

dest="$HOME/Applications/Needs You.app"
was_running=0
if pgrep -xq NeedsYou; then was_running=1; pkill -x NeedsYou || true; sleep 0.5; fi
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$dest"
cp -R "$app" "$dest"
ln -sf "$dest/Contents/Helpers/needs-you" "$HOME/.local/bin/needs-you"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true


# Local speech models (Parakeet, Kokoro): downloaded and compiled once into
# ~/Library/Application Support/FluidAudio/Models, never committed.
if [ "${SKIP_MODELS:-0}" != 1 ]; then
  "$dest/Contents/MacOS/NeedsYou" --download-models
fi

# The app may have come back on its own (login item) before the copy finished,
# still running the old binary: restart it once more.
if pgrep -xq NeedsYou; then pkill -x NeedsYou || true; sleep 1; fi
open -g "$dest"
echo "installed $dest, CLI at ~/.local/bin/needs-you"
