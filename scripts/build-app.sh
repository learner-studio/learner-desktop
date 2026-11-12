#!/usr/bin/env bash
set -euo pipefail

# BUNDLE_ONLY=1 builds and signs the bundle into OUT_DIR (default menu-bar-app/) and
# stops there: no install, no launchctl. The heavy test lane uses it.
# LEARNER_APP_BUNDLE=<path to .app> skips the build: that bundle (the one CI tested, from
# scripts/install-latest.sh) is re-signed with this Mac's identity and installed.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Learner Desktop.app"
OUT_DIR="${OUT_DIR:-${PROJECT_DIR}/menu-bar-app}"
BUNDLE_DIR="${OUT_DIR}/${APP_NAME}"
TARGET_APP="${HOME}/Applications/${APP_NAME}"

# Voice ID's speaker model, and (to compile) sherpa-onnx's static libraries: both come from
# scripts/fetch-voice-id.sh, not git. Checked first, so a missing one fails before the build.
VOICE_MODEL="${PROJECT_DIR}/menu-bar-app/Models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"
if [ -z "${LEARNER_APP_BUNDLE:-}" ] && { [ ! -f "${VOICE_MODEL}" ] || { [ -z "${LEARNER_BINARY:-}" ] && [ ! -d "${PROJECT_DIR}/third_party/sherpa-onnx/artifacts/sherpa-onnx.xcframework" ]; }; }; then
  echo "Voice ID's model or sherpa-onnx is missing: run scripts/fetch-voice-id.sh first" >&2
  exit 1
fi

if [ -n "${LEARNER_APP_BUNDLE:-}" ]; then
  [ -x "${LEARNER_APP_BUNDLE}/Contents/MacOS/learner-desktop" ] || { echo "LEARNER_APP_BUNDLE is not a Learner Desktop bundle: ${LEARNER_APP_BUNDLE}" >&2; exit 1; }
  echo "Using the prebuilt bundle ${LEARNER_APP_BUNDLE} (not compiling)..."
  rm -rf "${BUNDLE_DIR}"
  mkdir -p "$(dirname "${BUNDLE_DIR}")"
  ditto "${LEARNER_APP_BUNDLE}" "${BUNDLE_DIR}"
else
# LEARNER_BINARY: package an already-built binary instead of compiling (the heavy test
# lane uses the debug build, so checking the bundle takes seconds, not a release build).
if [ -n "${LEARNER_BINARY:-}" ]; then
  BINARY="${LEARNER_BINARY}"
else
  echo "Compiling Swift menu bar binary..."
  (cd "${PROJECT_DIR}" && swift build -c release --product LearnerDesktop)
  BINARY="${PROJECT_DIR}/.build/release/LearnerDesktop"
fi

echo "Creating Application bundle structure..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BINARY}" "${BUNDLE_DIR}/Contents/MacOS/learner-desktop"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/learner-desktop"

# The on-device speech detector's model (Silero VAD, Core ML).
cp -R "${PROJECT_DIR}/menu-bar-app/Models/silero-vad.mlmodelc" "${BUNDLE_DIR}/Contents/Resources/silero-vad.mlmodelc"

# Voice ID: the speaker model and sherpa-onnx's notices. sherpa-onnx and ONNX Runtime are
# linked statically into the binary: no framework to embed or sign.
cp "${VOICE_MODEL}" "${BUNDLE_DIR}/Contents/Resources/"
cp "${PROJECT_DIR}/third_party/sherpa-onnx/NOTICE" "${BUNDLE_DIR}/Contents/Resources/sherpa-onnx-NOTICE.txt"
cp "${PROJECT_DIR}/third_party/sherpa-onnx/LICENSE" "${BUNDLE_DIR}/Contents/Resources/sherpa-onnx-LICENSE.txt"

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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Learner Desktop pairing link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>learner-desktop</string>
            </array>
        </dict>
    </array>
        <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Learner Desktop listens for your own speech on the microphone, on this Mac only (no audio is stored or sent), to time how long you have been talking and, with Voice ID on, to tell your voice from others'.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>When you enroll your voice for Voice ID, Learner Desktop follows your reading of the enrollment passage so each word turns green as you say it. Recognition runs on this Mac only; nothing is sent or stored, and it is used for nothing else.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Learner Desktop connects directly to your Pavlok wearable wristband over Bluetooth Low Energy for instant, sub-15ms physical speech coaching feedback.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Learner Desktop communicates with your Pavlok wearable wristband over Bluetooth Low Energy for immediate haptic and shock speech coaching.</string>
</dict>
</plist>
EOF
fi

# Sign with a real Apple-issued identity so the app keeps the same identity across
# rebuilds. Ad-hoc signing (-) changes the code hash every build, and macOS TCC keys
# its grants (Bluetooth, Documents, ...) to that identity -- so every rebuild re-prompted.
# Referenced by name, not hash, so the annual certificate renewal does not break this.
# LEARNER_SIGN_IDENTITY overrides; otherwise the first Apple Development identity.
SIGN_IDENTITY="${LEARNER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
echo "Code-signing with: ${SIGN_IDENTITY:-ad-hoc}"
if [ -n "${SIGN_IDENTITY}" ] && security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${BUNDLE_DIR}"
  codesign --verify --strict "${BUNDLE_DIR}"
else
  echo "  ! signing identity not found in Keychain; falling back to ad-hoc (TCC will re-prompt per build)" >&2
  codesign --force --sign - "${BUNDLE_DIR}"
fi

if [ "${BUNDLE_ONLY:-0}" = 1 ]; then
  echo "Built ${BUNDLE_DIR} (BUNDLE_ONLY: not installed)"
  exit 0
fi

echo "Installing to ~/Applications/..."
mkdir -p "${HOME}/Applications" "${HOME}/Library/LaunchAgents" "${HOME}/.ai-aggregator/logs"
rm -rf "${TARGET_APP}"
cp -R "${BUNDLE_DIR}" "${TARGET_APP}"

AGENT_LABEL="com.benpollack.learner-desktop"
# The checked-in LaunchAgent names the owner's home; any other user (a CI runner) gets
# the same file with its own home in those paths. On the owner's Mac nothing changes.
AGENT_SRC="$(mktemp "${TMPDIR:-/tmp}/learner-agent.XXXXXX")"
trap 'rm -f "${AGENT_SRC}"' EXIT
sed "s#/Users/benpollack/#${HOME}/#g" "${PROJECT_DIR}/menu-bar-app/${AGENT_LABEL}.plist" > "${AGENT_SRC}"
chmod 644 "${AGENT_SRC}"
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
