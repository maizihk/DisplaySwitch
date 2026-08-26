#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DisplaySwitcher"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
DERIVED_DATA="$PROJECT_DIR/.build/xcode"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
ARCH="$(/usr/bin/uname -m)"

cd "$PROJECT_DIR"
mkdir -p "$OUTPUT_DIR"

/usr/bin/xcodebuild \
    -project "$PROJECT_DIR/DisplaySwitcher.xcodeproj" \
    -scheme DisplaySwitcher \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=$ARCH" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build

test -d "$BUILT_APP"

rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$BUILT_APP" "$APP_DIR"
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
# File Provider volumes can recreate an empty FinderInfo attribute while signing.
/usr/bin/xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
