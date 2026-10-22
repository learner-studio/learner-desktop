#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/Users/benpollack/code/learner-desktop"
APP_NAME="Learner Desktop.app"
BUNDLE_DIR="${PROJECT_DIR}/menu-bar-app/${APP_NAME}"
TARGET_APP="/Users/benpollack/Applications/${APP_NAME}"
BUN_BIN="${HOME}/.bun/bin/bun"

echo "Compiling Swift menu bar binary..."
swiftc -O -lsqlite3 "${PROJECT_DIR}/menu-bar-app/main.swift" -o "${PROJECT_DIR}/menu-bar-app/learner-desktop"

echo "Creating Application bundle structure..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${PROJECT_DIR}/menu-bar-app/learner-desktop" "${BUNDLE_DIR}/Contents/MacOS/"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/learner-desktop"

# The app runs the SSH tunnel and the transcript watcher itself, from its own bundle.
# They used to be separate /bin/bash LaunchAgents, which Login Items lists as "bash"
# from an unknown developer -- and once switched off there they silently stopped
# starting at login. The watcher is compiled to one self-contained file so the app
# never runs code out of ~/Documents.
echo "Bundling the tunnel and transcript watcher..."
cp "${PROJECT_DIR}/scripts/tunnel.sh" "${BUNDLE_DIR}/Contents/Resources/tunnel.sh"
chmod +x "${BUNDLE_DIR}/Contents/Resources/tunnel.sh"
"${BUN_BIN}" build "${PROJECT_DIR}/src/cli.ts" --target=bun --outfile "${BUNDLE_DIR}/Contents/Resources/learner-watcher.js"

# CFBundleIdentifier deliberately keeps its pre-rename value: TCC grants (Bluetooth) and
# the saved Pavlok settings in UserDefaults are keyed to it.
cat << 'EOF' > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>learner-desktop</string>
    <key>CFBundleIdentifier</key>
    <string>com.benpollack.ai-aggregator-menubar</string>
    <key>CFBundleName</key>
    <string>Learner Desktop</string>
    <key>CFBundleDisplayName</key>
    <string>Learner Desktop</string>
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
    <string>Learner Desktop connects directly to your Pavlok wearable wristband over Bluetooth Low Energy for instant, sub-15ms physical speech coaching feedback.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Learner Desktop communicates with your Pavlok wearable wristband over Bluetooth Low Energy for immediate haptic and shock speech coaching.</string>
</dict>
</plist>
EOF

# Sign with a real Apple-issued identity so the app keeps the same identity across
# rebuilds. Ad-hoc signing (-) changes the code hash every build, and macOS TCC keys
# its grants (Bluetooth, Documents, ...) to that identity -- so every rebuild re-prompted.
# Referenced by name, not hash, so the annual certificate renewal does not break this.
SIGN_IDENTITY="Apple Development: Benjamin Andrew Pollack (TTR89UH3PK)"
echo "Code-signing with: ${SIGN_IDENTITY}"
if security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${BUNDLE_DIR}"
  codesign --verify --strict "${BUNDLE_DIR}"
else
  echo "  ! signing identity not found in Keychain; falling back to ad-hoc (TCC will re-prompt per build)" >&2
  codesign --force --sign - "${BUNDLE_DIR}"
fi

echo "Installing to ~/Applications/..."
rm -rf "${TARGET_APP}"
cp -R "${BUNDLE_DIR}" "${TARGET_APP}"

AGENT_LABEL="com.benpollack.learner-desktop"
AGENT_SRC="${PROJECT_DIR}/menu-bar-app/${AGENT_LABEL}.plist"
AGENT_DST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"

if cmp -s "${AGENT_SRC}" "${AGENT_DST}" 2>/dev/null; then
  # Plist unchanged: restart in place. kickstart -k delivers SIGTERM, which the app
  # handles as a clean shutdown, and does not re-register the login item -- so macOS
  # does not show the "App Background Activity" notification.
  echo "Restarting Learner Desktop (LaunchAgent unchanged)..."
  launchctl kickstart -k "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null \
    || launchctl bootstrap "gui/$(id -u)" "${AGENT_DST}"
else
  echo "Installing updated LaunchAgent (KeepAlive only on crash, so Quit stays quit)..."
  cp "${AGENT_SRC}" "${AGENT_DST}"
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
  # bootout returns before the job is fully torn down; bootstrapping too early fails
  # with "Input/output error" (5). Wait for the label to leave the domain first.
  for _ in $(seq 1 30); do
    launchctl print "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  launchctl bootstrap "gui/$(id -u)" "${AGENT_DST}"
fi

echo "Successfully built and installed ${TARGET_APP}!"
