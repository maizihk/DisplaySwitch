#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DisplaySwitcher"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
DERIVED_DATA="$PROJECT_DIR/.build/xcode"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
ARCH="$(/usr/bin/uname -m)"
ARCHIVE_PATH="$OUTPUT_DIR/$APP_NAME-macOS-$ARCH.zip"

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
# File Provider volumes can recreate Finder/resource attributes while signing.
# They are not part of the executable signature and must be cleared afterwards.
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

STAGING_DIR="$(/usr/bin/mktemp -d /private/tmp/DisplaySwitcher-package.XXXXXX)"
trap '/bin/rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
EXTRACTED_DIR="$STAGING_DIR/extracted"

/usr/bin/ditto --norsrc "$APP_DIR" "$STAGED_APP"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
/bin/rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGED_APP" "$ARCHIVE_PATH"
/bin/mkdir -p "$EXTRACTED_DIR"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACTED_DIR"
/usr/bin/codesign --verify --deep --strict "$EXTRACTED_DIR/$APP_NAME.app"

echo "$APP_DIR"
echo "$ARCHIVE_PATH"
