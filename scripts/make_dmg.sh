#!/bin/zsh
# Makes build/Cutgenie-<version>.dmg: a disk image with Cutgenie.app and a shortcut to Applications (drag to install).
# Builds the app first. Nothing is installed or changed outside the build folder.
set -e
cd "$(dirname "$0")/.."
zsh scripts/build_app.sh
APP=build/Cutgenie.app
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT=build/Cutgenie-$VER.dmg
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Cutgenie.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -quiet -volname "Cutgenie" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
echo "made $OUT ($(du -h "$OUT" | cut -f1))"
