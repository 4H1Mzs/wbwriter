#!/usr/bin/env bash
# Builds a universal, Developer ID–signed WBWrite.app (and notarizes it when a
# notarytool keychain profile is available).
#
#   scripts/build.sh                       # build + sign
#   NOTARY_PROFILE=WBWrite scripts/build.sh  # build + sign + notarize + staple
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
NDI_SDK="${NDI_SDK:-/Library/NDI SDK for Apple}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Simon Cechacek (5BNMD65YZJ)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

APP="build/WBWrite.app"
C="$APP/Contents"

echo "==> Compiling (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WBWrite"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
cp "$BIN" "$C/MacOS/WBWrite"
cp "$NDI_SDK/lib/macOS/libndi.dylib" "$C/Frameworks/"
cp "$NDI_SDK/lib/macOS/libndi_licenses.txt" "$C/Resources/"
cp Assets/AppIcon.icns Assets/4h1m-logo.png Assets/4h1m-logo-white.png "$C/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$C/Info.plist"
# Drop the dev-only rpath to the SDK so only the bundled runtime is ever loaded.
install_name_tool -delete_rpath "$NDI_SDK/lib/macOS" "$C/MacOS/WBWrite" 2>/dev/null || true

echo "==> Signing with: $SIGN_ID"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$C/Frameworks/libndi.dylib"
codesign --force --timestamp --options runtime --entitlements Resources/WBWrite.entitlements \
  --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() { # file
  [[ -n "$NOTARY_PROFILE" ]] || return 0
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

ZIP="build/WBWrite-$VERSION.zip"
rm -f "$ZIP"
if [[ -n "$NOTARY_PROFILE" ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building DMG"
DMG="build/WBWrite-$VERSION.dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "WBWrite $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
notarize "$DMG" && [[ -n "$NOTARY_PROFILE" ]] && xcrun stapler staple "$DMG"

# Installer package needs a "Developer ID Installer" certificate.
INSTALLER_ID="${INSTALLER_ID:-$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)}"
PKG="build/WBWrite-$VERSION.pkg"
rm -f "$PKG"
if [[ -n "$INSTALLER_ID" ]]; then
  echo "==> Building installer package ($INSTALLER_ID)"
  pkgbuild --component "$APP" --install-location /Applications \
    --identifier com.cechacek.wbwrite.pkg --version "$VERSION" build/WBWrite-unsigned.pkg
  productsign --timestamp --sign "$INSTALLER_ID" build/WBWrite-unsigned.pkg "$PKG"
  rm -f build/WBWrite-unsigned.pkg
  notarize "$PKG" && [[ -n "$NOTARY_PROFILE" ]] && xcrun stapler staple "$PKG"
else
  echo "==> Skipping .pkg (no Developer ID Installer certificate in keychain)"
fi

spctl --assess --type execute --verbose=2 "$APP" || true
echo "==> Done: $APP  $ZIP  $DMG ${INSTALLER_ID:+ $PKG}"
