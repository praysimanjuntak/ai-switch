#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

swift build -c release

APP_DIR="$PROJECT_DIR/.build/AI Switch.app"
ARCHIVE_PATH="$PROJECT_DIR/.build/AI-Switch-macOS.zip"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/release/AISwitch" "$MACOS_DIR/AISwitch"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
chmod 755 "$MACOS_DIR/AISwitch"

codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

print "Built: $APP_DIR"
print "Archive: $ARCHIVE_PATH"
