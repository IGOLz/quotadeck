#!/bin/zsh
# Builds QuotaDeck.app (release, ad-hoc signed by default) with its WidgetKit extension in
# Contents/PlugIns. Pass --install to copy it to ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal by default (Intel and Apple silicon). ARCHS="arm64" builds faster for local use.
# The host-like arch goes last: the App Intents step below reads its compiled modules.
ARCHS=(${=ARCHS:-x86_64 arm64})
ARCH="${ARCHS[-1]}"
STAGE="$(mktemp -d)"
for arch in "${ARCHS[@]}"; do
  swift build -c release --arch "$arch" --product QuotaDeck
  swift build -c release --arch "$arch" --product QuotaDeckWidget
  BIN="$(swift build -c release --arch "$arch" --show-bin-path)"
  mkdir -p "$STAGE/$arch"
  cp "$BIN/QuotaDeck" "$BIN/QuotaDeckWidget" "$STAGE/$arch/"
done

APP=build/QuotaDeck.app
APPEX="$APP/Contents/PlugIns/QuotaDeckWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

mkdir -p "$APPEX/Contents/Resources"
lipo -create "$STAGE"/*/QuotaDeck -output "$APP/Contents/MacOS/QuotaDeck"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/Logos/codex.png "$APP/Contents/Resources/"
lipo -create "$STAGE"/*/QuotaDeckWidget -output "$APPEX/Contents/MacOS/QuotaDeckWidget"
rm -rf "$STAGE"
cp Resources/Widget/Info.plist "$APPEX/Contents/"
cp Resources/Logos/codex.png "$APPEX/Contents/Resources/"
strip -x "$APP/Contents/MacOS/QuotaDeck" "$APPEX/Contents/MacOS/QuotaDeckWidget"

# App Intents metadata for the widget's "Account" picker (Xcode normally generates this):
# the compiler extracts the intents' constant values, then Apple's processor turns them
# into Contents/Resources/Metadata.appintents.
AI="$(mktemp -d)"
SDK="$(xcrun --show-sdk-path)"
WIDGET_SOURCES=(Sources/QuotaDeckWidget/*.swift)
cat > "$AI/protocols.json" <<'JSON'
["AppIntent","AppEntity","AppEnum","EntityQuery","EntityStringQuery","EntityPropertyQuery",
 "EnumerableEntityQuery","TransientAppEntity","UniqueAppEntity","IndexedEntity",
 "WidgetConfigurationIntent","ControlConfigurationIntent","DynamicOptionsProvider",
 "AppShortcutsProvider","AppIntentsPackage","_IntentValue"]
JSON
: > "$AI/sources.txt"; : > "$AI/constvals.txt"
for src in "${WIDGET_SOURCES[@]}"; do
  out="$AI/$(basename "$src" .swift).swiftconstvalues"
  others=("${(@)WIDGET_SOURCES:#$src}")
  xcrun swiftc -frontend -typecheck -primary-file "$src" "${others[@]}" \
    -module-name QuotaDeckWidget -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos14.0" -sdk "$SDK" -I "$BIN" \
    -emit-const-values-path "$out" -const-gather-protocols-file "$AI/protocols.json"
  echo "$PWD/$src" >> "$AI/sources.txt"
  echo "$out" >> "$AI/constvals.txt"
done
xcrun appintentsmetadataprocessor --output "$APPEX/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
  --module-name QuotaDeckWidget --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS --deployment-target 14.0 --target-triple "$ARCH-apple-macos14.0" \
  --source-file-list "$AI/sources.txt" --swift-const-vals-list "$AI/constvals.txt" \
  --force --quiet-warnings 2>&1 | grep -viE "^\S+ \S+ appintentsmetadataprocessor\[" || true
rm -rf "$AI"
[[ -f "$APPEX/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || { echo "App Intents metadata missing" >&2; exit 1; }

# Inside out: the extension (sandboxed) first, then the app.
# SIGN_IDENTITY defaults to ad-hoc ("-"); set it to a "Developer ID Application: …"
# identity for a distributable build (see scripts/release.sh).
SIGN=(--force --sign "${SIGN_IDENTITY:--}" --options runtime)
[[ "${SIGN_IDENTITY:--}" != "-" ]] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" --entitlements Resources/Widget/QuotaDeckWidget.entitlements "$APPEX"
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST=~/Applications/QuotaDeck.app
  pkill -x QuotaDeck 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf "$DEST"
  cp -R "$APP" ~/Applications/
  # New modification date so Finder, the Dock and Spotlight drop their cached icon.
  touch "$DEST" "$DEST/Contents" "$DEST/Contents/Info.plist"
  # Register the app and its widget extension so they show up in the widget gallery.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/QuotaDeckWidget.appex"
  open "$DEST"
  echo "Installed to $DEST"
fi
