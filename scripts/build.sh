#!/bin/zsh
# Builds QuotaDeck.app (release, ad-hoc signed). Pass --install to copy it to
# ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/QuotaDeck"

APP=build/QuotaDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
strip -x "$APP/Contents/MacOS/QuotaDeck"
codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x QuotaDeck 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/QuotaDeck.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/QuotaDeck.app
  echo "Installed to ~/Applications/QuotaDeck.app"
fi
