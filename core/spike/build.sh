#!/bin/sh
# Builds the one-file capture app (the spike's test app, docs/PLAN-core.md P0) for the simulator
# (build/spike/IGSpike.app), linking core/build.sh's library.
# Run core/build.sh first. Install: xcrun simctl install <sim> build/spike/IGSpike.app (bundle com.example.igspike).
set -eu
cd "$(dirname "$0")"
lib=../../build/core/sim
app=../../build/spike/IGSpike.app
rm -rf "$app" && mkdir -p "$app"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -swift-version 5 -parse-as-library -O \
  -import-objc-header "$lib/include/libigcore.h" App.swift \
  -L"$lib" -ligcore -framework CoreFoundation -framework Security -lresolv -Xlinker -dead_strip -o "$app/IGSpike"
cat >"$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.igspike</string>
<key>CFBundleExecutable</key><string>IGSpike</string>
<key>CFBundleName</key><string>IG spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>igcapture</string></array></dict></array>
</dict></plist>
PLIST
codesign -s - --force "$app" >/dev/null 2>&1
echo "build/spike/IGSpike.app"
