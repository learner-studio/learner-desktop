#!/usr/bin/env bash
#
# SSH tunnel to the OVH box. Learner Desktop runs this from its app bundle and restarts
# it whenever it exits; run it by hand only when the app is not running.
#
set -euo pipefail

PORT=3200
TARGET_HOST="ovh"
AUTOSSH_BIN="/opt/homebrew/bin/autossh"

if [ ! -x "$AUTOSSH_BIN" ]; then
  AUTOSSH_BIN="$(command -v autossh || command -v ssh)"
fi

# Check if port is already listening and responsive
if lsof -i :$PORT >/dev/null 2>&1; then
  if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
    echo "Tunnel on port ${PORT} is already active and healthy."
    exit 0
  else
    echo "Port ${PORT} is in use but unresponsive. Killing stale processes..."
    lsof -ti :$PORT | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
fi

# Uploads go to learner-server over HTTPS; only GrowthBook's UI still needs the tunnel.
echo "Starting autossh tunnel to ${TARGET_HOST} (GrowthBook :3200)..."
export AUTOSSH_GATETIME=0
exec "$AUTOSSH_BIN" -M 0 -N \
  -o "ServerAliveInterval 15" \
  -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -o "StrictHostKeyChecking accept-new" \
  -L "3200:127.0.0.1:3200" \
  "$TARGET_HOST"
