#!/usr/bin/env bash
# Build Lovejoy.app from the SwiftPM executable target.
#
# Usage:
#   ./scripts/build-app.sh              # Release build for host arch, produces ./build/Lovejoy.app
#   CONFIG=debug ./scripts/build-app.sh # Debug build
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh  # Universal build (requires each arch toolchain)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${CONFIG:-release}"
APP_NAME="Lovejoy"
BUNDLE_ID="com.lovejoy.app"
OUT_DIR="$ROOT_DIR/build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Cleaning previous build"
# Kill any running instance so the user never accidentally tests an old binary.
pkill -x "Lovejoy" 2>/dev/null || true
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

cp "$ROOT_DIR/Sources/Lovejoy/Resources/Info.plist" "$CONTENTS/Info.plist"

# Bump CFBundleVersion to the build stamp so each rebuild is visibly distinct
# in the popover footer — easy way to catch "running stale binary" bugs.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_STAMP" "$CONTENTS/Info.plist" 2>/dev/null || true

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
    for candidate in "Developer ID Application" "Apple Development" "Lovejoy Self-Signed"; do
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
    echo "    If Lovejoy doesn't appear in Input Monitoring, use the 'Reveal App' /"
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
echo "  tccutil reset ListenEvent  com.lovejoy.app"
echo "  tccutil reset Accessibility com.lovejoy.app"
echo "then relaunch. You can also click + in System Settings and add:"
echo "  $APP_BUNDLE"
