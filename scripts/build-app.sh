#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/Users/benpollack/Documents/AI aggregator logger project"
APP_NAME="AI Aggregator.app"
BUNDLE_DIR="${PROJECT_DIR}/menu-bar-app/${APP_NAME}"
TARGET_APP="/Users/benpollack/Applications/${APP_NAME}"

echo "Compiling Swift menu bar binary..."
swiftc -O -lsqlite3 "${PROJECT_DIR}/menu-bar-app/main.swift" -o "${PROJECT_DIR}/menu-bar-app/ai-aggregator-menubar"

echo "Creating Application bundle structure..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${PROJECT_DIR}/menu-bar-app/ai-aggregator-menubar" "${BUNDLE_DIR}/Contents/MacOS/"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/ai-aggregator-menubar"

cat << 'EOF' > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ai-aggregator-menubar</string>
    <key>CFBundleIdentifier</key>
    <string>com.benpollack.ai-aggregator-menubar</string>
    <key>CFBundleName</key>
    <string>AI Aggregator</string>
    <key>CFBundleDisplayName</key>
    <string>AI Aggregator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AI Aggregator connects directly to your Pavlok wearable wristband over Bluetooth Low Energy for instant, sub-15ms physical speech coaching feedback.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>AI Aggregator communicates with your Pavlok wearable wristband over Bluetooth Low Energy for immediate haptic and shock speech coaching.</string>
</dict>
</plist>
EOF

echo "Installing to ~/Applications/..."
rm -rf "${TARGET_APP}"
cp -R "${BUNDLE_DIR}" "${TARGET_APP}"

echo "Restarting AI Aggregator LaunchAgent..."
launchctl kickstart -k "gui/$(id -u)/com.benpollack.ai-aggregator-app" 2>/dev/null || true

echo "Successfully built and installed ${TARGET_APP}!"
