#!/bin/zsh
set -euo pipefail
umask 022

# Builds a beta disk image, not a notarized public release.
# Only explicit release files are copied; never package the workspace or .build.
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Expected a numeric major.minor.patch version in Resources/Info.plist."
    exit 1
fi

DIST_DIR="$PROJECT_DIR/dist"
DMG_NAME="AI-Switch-$VERSION-macOS-universal-beta.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" ]]; then
    print -u2 "A release with this version already exists in dist. Move it aside or increment the version before rebuilding."
    exit 1
fi

zsh Scripts/test.sh

# Separate scratch paths work with Apple's Command Line Tools, without Xcode.
for ARCH in arm64 x86_64; do
    if [[ "$ARCH" == arm64 ]]; then
        SCRATCH="$PROJECT_DIR/.build/distribution-arm64"
    else
        SCRATCH="$PROJECT_DIR/.build/distribution-intel"
    fi
    swift build -c release --product AISwitch --triple "$ARCH-apple-macosx14.0" \
        --scratch-path "$SCRATCH" -debug-info-format none
done

ARM_BIN=$(swift build -c release --triple arm64-apple-macosx14.0 \
    --scratch-path "$PROJECT_DIR/.build/distribution-arm64" --show-bin-path)
INTEL_BIN=$(swift build -c release --triple x86_64-apple-macosx14.0 \
    --scratch-path "$PROJECT_DIR/.build/distribution-intel" --show-bin-path)

STAGING_DIR=$(mktemp -d "$PROJECT_DIR/.build/dmg-stage.XXXXXX")
PAYLOAD_DIR="$STAGING_DIR/payload"
APP_DIR="$PAYLOAD_DIR/AI Switch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

xcrun lipo -create "$ARM_BIN/AISwitch" "$INTEL_BIN/AISwitch" \
    -output "$APP_DIR/Contents/MacOS/AISwitch"
xcrun strip -S "$APP_DIR/Contents/MacOS/AISwitch"
chmod 755 "$APP_DIR/Contents/MacOS/AISwitch"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict --all-architectures "$APP_DIR"
xcrun lipo "$APP_DIR/Contents/MacOS/AISwitch" -verify_arch arm64 x86_64

ln -s /Applications "$PAYLOAD_DIR/Applications"
cp Resources/Distribution-Readme.txt "$PAYLOAD_DIR/Read Me.txt"

# Finish and verify the image before publishing it to dist. Staging remains in
# .build for inspection; the existing installed app is never touched.
hdiutil create -volname "AI Switch" -srcfolder "$PAYLOAD_DIR" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$STAGING_DIR/$DMG_NAME"
hdiutil verify "$STAGING_DIR/$DMG_NAME"
mv "$STAGING_DIR/$DMG_NAME" "$DMG_PATH"
(
    cd "$DIST_DIR"
    shasum -a 256 "$DMG_NAME" > "$CHECKSUM_PATH"
)

print "DMG: $DMG_PATH"
print "Checksum: $CHECKSUM_PATH"
print "Beta only: ad-hoc signed, not notarized. macOS Gatekeeper will not treat this as a trusted public release."
