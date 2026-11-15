#!/bin/sh
# build.sh: Streaming Dashboard (Mantra).app, swiftc straight, no Xcode. Run ONLY by GitHub Actions
# (.github/workflows/build.yml; MANTRA_MANIFEST android-app.md §0: nothing compiles on the Mac). The version is VERSION in
# app/App.swift. collector.py goes into Resources: the app sends it to the VM over ssh at every poll.
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Streaming Dashboard (Mantra)"
APP="build/$NAME.app"
rm -rf build; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -o "$APP/Contents/MacOS/StreamingDashboard" app/*.swift
[ -x "$APP/Contents/MacOS/StreamingDashboard" ] || { echo "the app did not build"; exit 1; }
cp app/collector.py "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.streamingdashboard</string>
<key>CFBundleExecutable</key><string>StreamingDashboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Streaming Dashboard (Mantra) reads the numbers of the streams from the cloud machine over Tailscale (100.102.86.30).</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PL
swift icon/make_icon.swift "$V" build/icon_1024.png
I=build/AppIcon.iconset; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
