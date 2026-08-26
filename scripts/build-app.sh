#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DisplaySwitcher"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
STAGE_DIR="$(mktemp -d /private/tmp/display-switcher.XXXXXX)"
STAGE_APP="$STAGE_DIR/$APP_NAME.app"
trap '/bin/rm -rf "$STAGE_DIR"' EXIT

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"

SDK_PATH="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
ARCH="$(/usr/bin/uname -m)"
BIN_DIR="$PROJECT_DIR/.build/release"
SOURCE_FILES=("$PROJECT_DIR"/Sources/DisplaySwitcher/*.swift)
mkdir -p "$BIN_DIR" "$OUTPUT_DIR"

"$SWIFTC" \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-macos12.0" \
    -O \
    -framework AppKit \
    -framework IOKit \
    -framework Network \
    -framework ServiceManagement \
    "${SOURCE_FILES[@]}" \
    -o "$BIN_DIR/$APP_NAME"

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp -X "$BIN_DIR/$APP_NAME" "$STAGE_APP/Contents/MacOS/$APP_NAME"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
cp -X "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign - "$STAGE_APP"
/usr/bin/codesign --verify --deep --strict "$STAGE_APP"

rm -rf "$APP_DIR"
cp -RX "$STAGE_APP" "$APP_DIR"
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
