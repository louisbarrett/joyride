#!/usr/bin/env bash
# Build Joyride.app from the SwiftPM executable target.
#
# Usage:
#   ./scripts/build-app.sh              # Release build for host arch, produces ./build/Joyride.app
#   CONFIG=debug ./scripts/build-app.sh # Debug build
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh  # Universal build (requires each arch toolchain)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${CONFIG:-release}"
APP_NAME="Joyride"
BUNDLE_ID="com.joyride.app"
OUT_DIR="$ROOT_DIR/build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Cleaning previous build"
# Kill any running instance so the user never accidentally tests an old binary.
pkill -x "Joyride" 2>/dev/null || true
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BUILD_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

ARCHS="${ARCHS:-$(uname -m)}"
BUILT_BINARIES=()

for ARCH in $ARCHS; do
    echo "==> Building ($CONFIG, $ARCH)"
    swift build \
        --configuration "$CONFIG" \
        --arch "$ARCH"
    BIN_PATH="$(swift build --configuration "$CONFIG" --arch "$ARCH" --show-bin-path)/$APP_NAME"
    if [[ ! -f "$BIN_PATH" ]]; then
        echo "error: build did not produce $BIN_PATH" >&2
        exit 1
    fi
    BUILT_BINARIES+=("$BIN_PATH")
done

echo "==> Assembling app bundle"
if [[ ${#BUILT_BINARIES[@]} -gt 1 ]]; then
    lipo -create -output "$MACOS_DIR/$APP_NAME" "${BUILT_BINARIES[@]}"
else
    cp "${BUILT_BINARIES[0]}" "$MACOS_DIR/$APP_NAME"
fi
chmod +x "$MACOS_DIR/$APP_NAME"

cp "$ROOT_DIR/Sources/Joyride/Resources/Info.plist" "$CONTENTS/Info.plist"

# Bump CFBundleVersion to the build stamp so each rebuild is visibly distinct
# in the popover footer — easy way to catch "running stale binary" bugs.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_STAMP" "$CONTENTS/Info.plist" 2>/dev/null || true

# App icon. We build AppIcon.icns on the fly from icon_1024.png at the repo
# root using the system-provided `sips` and `iconutil` tools, so the repo only
# needs to track the single master PNG rather than a binary .icns.
ICON_MASTER="$ROOT_DIR/icon_1024.png"
if [[ -f "$ICON_MASTER" ]]; then
    echo "==> Generating AppIcon.icns from $(basename "$ICON_MASTER")"
    ICONSET_DIR="$(mktemp -d -t joyride-iconset)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"

    # macOS expects these 10 slots (5 logical sizes × @1x and @2x).
    sips -z 16 16     "$ICON_MASTER" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
    sips -z 32 32     "$ICON_MASTER" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
    sips -z 32 32     "$ICON_MASTER" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
    sips -z 64 64     "$ICON_MASTER" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
    sips -z 128 128   "$ICON_MASTER" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
    sips -z 256 256   "$ICON_MASTER" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$ICON_MASTER" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
    sips -z 512 512   "$ICON_MASTER" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$ICON_MASTER" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
    cp "$ICON_MASTER" "$ICONSET_DIR/icon_512x512@2x.png"

    iconutil --convert icns --output "$RESOURCES_DIR/AppIcon.icns" "$ICONSET_DIR"
    rm -rf "$(dirname "$ICONSET_DIR")"
else
    echo "==> WARNING: $ICON_MASTER not found; app will use the default generic icon."
    # Drop the icon keys so Finder doesn't cache a broken reference.
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

# Code signing.
#
# macOS's TCC subsystem (which gates Accessibility + Input Monitoring) identifies apps by
# their code signature. Ad-hoc signatures (`codesign --sign -`) don't produce a stable
# designated requirement, which is why an ad-hoc-signed build may silently fail to appear
# in the Privacy panes. Every rebuild hashes differently, so TCC may also churn.
#
# If SIGN_IDENTITY is set (to a Keychain identity — "Apple Development", "Developer ID
# Application", or even a self-signed "Code Signing" cert), we'll use it for a stable
# signature. Otherwise we fall back to ad-hoc and print a warning.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    # Auto-pick a reasonable stable identity if one is installed.
    for candidate in "Developer ID Application" "Apple Development" "Joyride Self-Signed"; do
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
            SIGN_IDENTITY="$candidate"
            break
        fi
    done
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Code signing with: $SIGN_IDENTITY"
    codesign --force --deep --timestamp=none --options runtime \
        --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "==> Ad-hoc code signing (set SIGN_IDENTITY for a stable signature)"
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo "    Note: ad-hoc signed apps may not auto-register in Privacy & Security panes."
    echo "    If Joyride doesn't appear in Input Monitoring, use the 'Reveal App' /"
    echo "    'Copy Path' buttons in the menu bar popover and add it with the + button."
fi

echo "==> Built: $APP_BUNDLE"
echo
echo "Run with:"
echo "  open \"$APP_BUNDLE\""
echo
echo "Required permissions (grant in System Settings → Privacy & Security):"
echo "  • Accessibility     — to synthesize keyboard/mouse/scroll events"
echo "  • Input Monitoring  — to read input from paired Joy-Cons"
echo
echo "If either permission prompt doesn't appear, or the app isn't listed, run:"
echo "  tccutil reset ListenEvent  com.joyride.app"
echo "  tccutil reset Accessibility com.joyride.app"
echo "then relaunch. You can also click + in System Settings and add:"
echo "  $APP_BUNDLE"
