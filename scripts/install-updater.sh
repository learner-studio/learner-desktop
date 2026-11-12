#!/usr/bin/env bash
#
# install-updater.sh -- turns on automatic updates on the owner's Mac: a LaunchAgent
# (com.benpollack.learner-desktop-updater) runs auto-update.sh every 5 minutes and at login.
# It installs main's newest CI-tested build, never during a call, and keeps itself current
# from each build's install kit. Log: ~/.ai-aggregator/logs/updater.log.
#
#   scripts/install-updater.sh            install (or refresh) and start it
#   scripts/install-updater.sh --remove   stop and remove it
#   pause / resume:  touch / rm "~/Library/Application Support/Learner Desktop/updater/PAUSED"
#
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

LABEL="com.benpollack.learner-desktop-updater"
UPDATER_DIR="${HOME}/Library/Application Support/Learner Desktop/updater"
AGENT="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
  rm -f "$AGENT"
  rm -rf "$UPDATER_DIR"
  echo "Automatic updates are off (the updater and its LaunchAgent are removed)."
  exit 0
fi

mkdir -p "$UPDATER_DIR" "${HOME}/Library/LaunchAgents" "${HOME}/.ai-aggregator/logs"
cp scripts/auto-update.sh "$UPDATER_DIR/auto-update.sh"
chmod +x "$UPDATER_DIR/auto-update.sh"

# zsh, not bash: it reads ~/.zshenv, where GH_TOKEN comes from the Keychain. launchd's own
# PATH has no Homebrew, where gh lives.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>exec "\$HOME/Library/Application Support/Learner Desktop/updater/auto-update.sh"</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${HOME}/.ai-aggregator/logs/updater.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.ai-aggregator/logs/updater.log</string>
</dict>
</plist>
PLIST
plutil -lint -s "$AGENT"

for _ in $(seq 1 20); do launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl bootstrap "$DOMAIN" "$AGENT"
echo "Automatic updates are on: every 5 minutes, main's newest CI-tested build is installed (never during a call)."
echo "Log: ~/.ai-aggregator/logs/updater.log"
