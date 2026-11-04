#!/bin/zsh
# Builds a signed, notarized QuotaDeck-<version>.zip ready to attach to a GitHub release.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. Notary credentials saved in the keychain:
#        xcrun notarytool store-credentials quotadeck-notary \
#          --apple-id <apple-id> --team-id <team-id>   # prompts for an app-specific password
#
# Usage: ./scripts/release.sh
# Optional env: SIGN_IDENTITY (defaults to the first Developer ID Application identity),
#               NOTARY_PROFILE (defaults to quotadeck-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-quotadeck-notary}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }
export SIGN_IDENTITY

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/QuotaDeck-$VERSION.zip"
echo "Releasing QuotaDeck $VERSION, signed by: $SIGN_IDENTITY"

./scripts/build.sh

# Notarize, staple the ticket to the app, then zip the stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent build/QuotaDeck.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/QuotaDeck.app
rm -f "$ZIP"
ditto -c -k --keepParent build/QuotaDeck.app "$ZIP"

spctl --assess --type execute --verbose build/QuotaDeck.app
echo "Ready: $ZIP"
shasum -a 256 "$ZIP"
