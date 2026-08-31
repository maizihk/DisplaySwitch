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
SIGNING_IDENTITY="${DISPLAYSWITCH_CODESIGN_IDENTITY:-}"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "DISPLAYSWITCH_CODESIGN_IDENTITY must name a keychain identity; unset it for ad-hoc signing." >&2
        exit 1
    fi
    if ! /usr/bin/security find-identity -p codesigning -v | /usr/bin/grep -Fq "$SIGNING_IDENTITY"; then
        echo "DISPLAYSWITCH_CODESIGN_IDENTITY does not match a valid code-signing identity." >&2
        exit 1
    fi
    CODESIGN_IDENTITY="$SIGNING_IDENTITY"
    SIGNING_MODE="Apple-issued local identity"
else
    CODESIGN_IDENTITY="-"
    SIGNING_MODE="ad-hoc"
fi

verify_app_signature() {
    local app_path="$1"
    /usr/bin/codesign --verify --deep --strict "$app_path"

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        local signature_details
        signature_details="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)"
        if ! /usr/bin/grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<<"$signature_details"; then
            echo "Signed app is missing an Apple team identifier." >&2
            exit 1
        fi
        if /usr/bin/grep -Fq 'Signature=adhoc' <<<"$signature_details"; then
            echo "Signed app unexpectedly has an ad-hoc signature." >&2
            exit 1
        fi
    fi
}

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
/usr/bin/codesign --force --deep --timestamp=none --sign "$CODESIGN_IDENTITY" "$APP_DIR"
# File Provider volumes can recreate Finder/resource attributes while signing.
# They are not part of the executable signature and must be cleared afterwards.
/usr/bin/xattr -cr "$APP_DIR"
verify_app_signature "$APP_DIR"

STAGING_DIR="$(/usr/bin/mktemp -d /private/tmp/DisplaySwitcher-package.XXXXXX)"
trap '/bin/rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
EXTRACTED_DIR="$STAGING_DIR/extracted"

/usr/bin/ditto --norsrc "$APP_DIR" "$STAGED_APP"
/usr/bin/xattr -cr "$STAGED_APP"
verify_app_signature "$STAGED_APP"
/bin/rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGED_APP" "$ARCHIVE_PATH"
/bin/mkdir -p "$EXTRACTED_DIR"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACTED_DIR"
verify_app_signature "$EXTRACTED_DIR/$APP_NAME.app"

echo "Signing mode: $SIGNING_MODE"
echo "$APP_DIR"
echo "$ARCHIVE_PATH"
