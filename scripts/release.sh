#!/bin/bash
# Builds a signed, notarized BudMeter DMG and publishes it as a GitHub release.
#
#   NOTARY_PROFILE=<keychain profile> scripts/release.sh 1.0.0
#
# Needs a "Developer ID Application" certificate in the keychain and notarization credentials
# stored with `xcrun notarytool store-credentials <profile> --key ... --key-id ... --issuer ...`.
# Set PUBLISH=0 to build and notarize without creating the GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: NOTARY_PROFILE=<profile> scripts/release.sh <version, e.g. 1.0.0>}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
TEAM_ID="${TEAM_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]*\))".*/\1/p' | head -1)}"
[ -n "$TEAM_ID" ] || { echo "No Developer ID Application certificate found"; exit 1; }
OUT=build/release
APP="$OUT/Build/Products/Release/BudMeter.app"
DMG="$OUT/BudMeter-$VERSION.dmg"

echo "Building BudMeter $VERSION ($BUILD_NUMBER) for team $TEAM_ID"
xcodegen generate --quiet
# Universal (Apple silicon and Intel), hardened runtime, no debugging entitlement: what notarization needs.
xcodebuild -project BudMeter.xcodeproj -scheme BudMeter -configuration Release -derivedDataPath "$OUT" -quiet \
  -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build
codesign --verify --deep --strict --verbose=1 "$APP"
lipo -archs "$APP/Contents/MacOS/BudMeter"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "The app still has the get-task-allow entitlement; notarization would reject it"; exit 1
fi

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    | tee "$OUT/notary.json" | grep -q '"status":"Accepted"' \
    || { echo "Notarization failed:"; cat "$OUT/notary.json"; exit 1; }
}

echo "Notarizing the app"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/BudMeter.zip"
notarize "$OUT/BudMeter.zip"
xcrun stapler staple "$APP"

echo "Making the disk image"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "BudMeter" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Built $DMG"

if [ "${PUBLISH:-1}" = "1" ]; then
  gh release create "v$VERSION" "$DMG" --title "BudMeter $VERSION" --target "$(git rev-parse HEAD)" \
    --notes "Download **BudMeter-$VERSION.dmg**, open it and drag BudMeter to Applications. Requires macOS 14 or later. The app is signed with a Developer ID and notarized by Apple."
fi
