#!/bin/zsh
# Packs the Claude desktop connector into build/Cutgenie.mcpb (a zip with manifest.json at the root).
# Double-click the file (or drag it into Claude ▸ Settings ▸ Extensions) to install it.
set -e
cd "$(dirname "$0")/.."
OUT=build/Cutgenie.mcpb
STAGE=$(mktemp -d /tmp/cutgenie-mcpb-XXXX)
mkdir -p build "$STAGE/server"
cp mcp/manifest.json mcp/package.json "$STAGE/"
cp mcp/server/index.js "$STAGE/server/"
sips -Z 256 Resources/Cutgenie-icon-amber-1024.png --out "$STAGE/icon.png" >/dev/null
node --check "$STAGE/server/index.js"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STAGE/manifest.json"
rm -f "$OUT"
(cd "$STAGE" && zip -qr -X "$OLDPWD/$OUT" manifest.json package.json icon.png server)
rm -rf "$STAGE"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
