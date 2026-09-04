#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/dist/Corplink Control.app"
CONTENTS_DIR="$APP_DIR/Contents"
SWIFT_BUILD=(/usr/bin/swift build -c release --arch arm64 --arch x86_64)
SIGN_IDENTITY="${CORPLINK_CODE_SIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
"${SWIFT_BUILD[@]}" --product CorplinkControlApp
"${SWIFT_BUILD[@]}" --product CorplinkRootHelper

BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Library/LaunchDaemons"
/bin/cp "$BIN_DIR/CorplinkControlApp" "$CONTENTS_DIR/MacOS/CorplinkControlApp"
/bin/cp "$BIN_DIR/CorplinkRootHelper" "$CONTENTS_DIR/Resources/corplink-root-helper"
/bin/cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/bin/cp "$PROJECT_DIR/Resources/local.sunyi.corplink-control.root-helper.plist" "$CONTENTS_DIR/Library/LaunchDaemons/"
/bin/cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/chmod 755 "$CONTENTS_DIR/MacOS/CorplinkControlApp" "$CONTENTS_DIR/Resources/corplink-root-helper"

/usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  --identifier local.sunyi.corplink-control.root-helper \
  "$CONTENTS_DIR/Resources/corplink-root-helper"
/usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "$APP_DIR"
