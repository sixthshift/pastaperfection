#!/bin/bash
# Assembles dist/Ampere.app from the release build (SPEC §2, §5 Phase 2).
# Idempotent: safe to re-run; always rebuilds and re-assembles from scratch.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PastaPerfection"   # user-facing name (bundle, Finder, menu bar app)
BINARY_NAME="Ampere"         # SPM target name — internal, unchanged
BUNDLE_ID="com.pastaperfection.app"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RELEASE_DIR=".build/release"

echo "==> Building release binaries"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_DIR/$BINARY_NAME" "$MACOS_DIR/$APP_NAME"

# Bundle the daemon and CLI binaries into Resources so the app (specifically
# the daemon-unavailable install prompt) can reference a known-good path to
# `ampere-cli install` without relying on anything outside the bundle.
cp "$RELEASE_DIR/ampered" "$RESOURCES_DIR/ampered"
cp "$RELEASE_DIR/ampere-cli" "$RESOURCES_DIR/ampere-cli"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign -s - --force --deep "$APP_DIR"

echo "==> Done: $APP_DIR"
