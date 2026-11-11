#!/usr/bin/env bash
# Builds a universal Release app and wraps it in a drag-to-install DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build-release"
DIST="$ROOT/dist"
APP="$BUILD_DIR/Build/Products/Release/MausBot.app"

echo "==> Building universal Release"
xcodebuild \
  -project "$ROOT/MausBot.xcodeproj" \
  -scheme MausBot \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build \
  > "$BUILD_DIR/package-build.log" 2>&1

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="MausBot-${VERSION}"
mkdir -p "$DIST"

# The Xcode project signs ad hoc ("Sign to Run Locally"). Pass a Developer ID
# to ship a build Gatekeeper accepts, then notarize it separately.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
fi

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
RW_IMAGE="$WORK/rw.dmg"
MOUNT="$WORK/volume"
mkdir -p "$STAGE" "$MOUNT"

cleanup() {
  hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Staging $NAME"
cp -R "$APP" "$STAGE/MausBot.app"
ln -s /Applications "$STAGE/Applications"

# A writable pass so the volume can carry the app icon, then compress.
hdiutil create -quiet -srcfolder "$STAGE" -volname "MausBot $VERSION" \
  -fs HFS+ -format UDRW -size 200m "$RW_IMAGE"
hdiutil attach "$RW_IMAGE" -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || true
fi
hdiutil detach "$MOUNT" -quiet -force >/dev/null

echo "==> Compressing"
rm -f "$DIST/$NAME.dmg"
hdiutil convert -quiet "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -o "$DIST/$NAME.dmg"

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/MausBot")"
echo "signature: $(codesign -dv "$APP" 2>&1 | awk -F'Signature=' '/Signature=/{print $2}')"
hdiutil verify "$DIST/$NAME.dmg" >/dev/null
echo "size: $(du -h "$DIST/$NAME.dmg" | cut -f1)"
echo "dmg: $DIST/$NAME.dmg"
