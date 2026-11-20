#!/bin/zsh
# Builds Cutzonical.app (code still says Cutzonical inside; the bundle id stays com.techzonical.cutzonical so settings carry over) and the cutzonicalctl tool using the Swift Package (no Xcode needed).
set -e
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -v "Developer/Library/Frameworks' not found" | grep -E "error:|Compiling|Build complete" | tail -5
swift build -c release >/dev/null 2>&1 || { echo "BUILD FAILED - app not updated"; exit 1; }
BIN=$(swift build -c release --show-bin-path)
APP=build/Cutzonical.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cutzonical" "$APP/Contents/MacOS/Cutzonical"
cp "$BIN/cutzonicalctl" build/cutzonicalctl
# Core Image Metal kernels (need the Metal toolchain from Xcode)
xcrun metal -c -fcikernel Sources/CutzonicalCore/Shaders/ColorKernels.ci.metal -o build/ColorKernels.air
xcrun metallib -cikernel build/ColorKernels.air -o "$APP/Contents/Resources/ColorKernels.metallib"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Cutzonical</string>
<key>CFBundleDisplayName</key><string>Cutzonical by TechZonical</string>
<key>CFBundleIdentifier</key><string>com.techzonical.cutzonical</string>
<key>CFBundleExecutable</key><string>Cutzonical</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
P
# a 1-second black clip used to fill gaps in the picture so graphic layers can be drawn there
[ -f build/black.mp4 ] || ffmpeg -v error -y -f lavfi -i "color=black:s=1920x1080:r=24:d=1" -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 build/black.mp4
cp build/black.mp4 "$APP/Contents/Resources/black.mp4"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "ad-hoc signed"
echo "built: $APP and build/cutzonicalctl"
