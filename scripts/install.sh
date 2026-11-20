#!/bin/zsh
# Installs the tested build into /Applications and makes build/Cutzonical.dmg (a disk image: drag Cutzonical to Applications).
# Run only after tests/check_all.py passes. Projects and media are not touched.
set -e
cd "$(dirname "$0")/.."
APP=build/Cutzonical.app
[ -d "$APP" ] || { echo "no $APP - build first"; exit 1; }
if pgrep -f "/Applications/Cutzonical.app/Contents/MacOS/Cutzonical" >/dev/null; then
  echo "Cutzonical from Applications is running - quit it first"; exit 1
fi
ditto "$APP" /Applications/Cutzonical.app
codesign -f -s - /Applications/Cutzonical.app >/dev/null 2>&1
echo "installed /Applications/Cutzonical.app"

# disk image with the app and a shortcut to Applications
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Cutzonical.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cutzonical" -srcfolder "$STAGE" -ov -format UDZO build/Cutzonical.dmg
rm -rf "$STAGE"
echo "made build/Cutzonical.dmg ($(du -h build/Cutzonical.dmg | cut -f1))"
