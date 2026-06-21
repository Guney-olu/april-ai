#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
APP_NAME="AprilAI"
BUNDLE_ID="com.local.aprilai"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$PROJECT_DIR/.build/debug/$APP_NAME"
RESET_PERMISSIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-permissions)
      RESET_PERMISSIONS=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--reset-permissions]" >&2
      exit 2
      ;;
  esac
done

cd "$PROJECT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
if [ -f "$PROJECT_DIR/Assets/AprilAI.icns" ]; then
  cp "$PROJECT_DIR/Assets/AprilAI.icns" "$RESOURCES_DIR/AprilAI.icns"
fi
if [ -f "$PROJECT_DIR/Assets/brain human.glb" ]; then
  cp "$PROJECT_DIR/Assets/brain human.glb" "$RESOURCES_DIR/brain human.glb"
fi

/usr/bin/plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "April AI" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "April AI" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string "AprilAI.icns" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "0.1.0" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "1" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "14.0" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSApplicationCategoryType -string "public.app-category.productivity" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSMicrophoneUsageDescription -string "April AI records push-to-talk audio only when you start voice input." "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSScreenCaptureDescription -string "April AI captures the screen only when you click Look at screen." "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string "April AI can open applications and use local Accessibility, keyboard, or mouse actions when you grant the required macOS permissions. It does not use Apple Events to automate apps." "$CONTENTS_DIR/Info.plist"

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

if [[ "$RESET_PERMISSIONS" -eq 1 ]]; then
  "$PROJECT_DIR/scripts/reset-permissions.sh" "$BUNDLE_ID"
fi

echo "$APP_DIR"
