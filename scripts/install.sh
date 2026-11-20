#!/bin/zsh
# Installs the tested build into /Applications and makes build/Cutgenie.dmg (a disk image: drag Cutgenie to Applications).
# Run only after tests/check_all.py passes. Projects and media are not touched.
set -e
cd "$(dirname "$0")/.."
APP=build/Cutgenie.app
[ -d "$APP" ] || { echo "no $APP - build first"; exit 1; }
if pgrep -f "/Applications/Cutgenie.app/Contents/MacOS/Cutgenie" >/dev/null; then
  echo "Cutgenie from Applications is running - quit it first"; exit 1
fi
ditto "$APP" /Applications/Cutgenie.app
codesign -f -s - /Applications/Cutgenie.app >/dev/null 2>&1
echo "installed /Applications/Cutgenie.app"

# disk image with the app and a shortcut to Applications
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Cutgenie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cutgenie" -srcfolder "$STAGE" -ov -format UDZO build/Cutgenie.dmg
rm -rf "$STAGE"
echo "made build/Cutgenie.dmg ($(du -h build/Cutgenie.dmg | cut -f1))"
