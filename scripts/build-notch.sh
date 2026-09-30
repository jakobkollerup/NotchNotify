#!/usr/bin/env bash
# Build a local app bundle. Does not launch, install, reset permissions, or register login items.
#
#   ARCHS="arm64 x86_64"   build a universal binary (default: this Mac's architecture)
#   NOTCH_SIGN_IDENTITY    codesigning identity (default: ad-hoc)
#   BUILD_NUMBER           CFBundleVersion (default: 1)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_ROOT="${NOTCH_BUILD_ROOT:-$PWD/.build}"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${NOTCH_SIGN_IDENTITY:--}"
VERSION="$(tr -d '[:space:]' < VERSION)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_ROOT/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$BUILD_ROOT"

BINARIES=()
for ARCH in $ARCHS; do
    BUILD_ARGS=(--disable-sandbox --cache-path "$BUILD_ROOT/cache" --scratch-path "$BUILD_ROOT/swift-$ARCH"
                -c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0")
    swift build "${BUILD_ARGS[@]}" --product NotchNotify
    BINARIES+=("$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/NotchNotify")
done

APP_DIR="$PWD/build/NotchNotify.app"
# Replace only this generated bundle so removed branding cannot survive a rebuild.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/NotchNotify"
cp Resources/NotchNotify-Info.plist "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP_DIR/Contents/Info.plist"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE.txt"
cp docs/THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/NotchNotify.icns "$APP_DIR/Contents/Resources/NotchNotify.icns"
cp -R Resources/Brand "$APP_DIR/Contents/Resources/Brand"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements Resources/NotchNotify.entitlements)
# Notarization requires the hardened runtime and a secure timestamp; ad-hoc signing supports neither.
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built %s %s (%s)\n' "$APP_DIR" "$VERSION" "$(lipo -archs "$APP_DIR/Contents/MacOS/NotchNotify")"
