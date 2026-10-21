#!/usr/bin/env bash
#
# SSH tunnel to the OVH box. Learner Desktop runs this from its app bundle and restarts
# it whenever it exits; run it by hand only when the app is not running.
#
set -euo pipefail

PORT=18925
TARGET_HOST="ovh"
AUTOSSH_BIN="/opt/homebrew/bin/autossh"

if [ ! -x "$AUTOSSH_BIN" ]; then
  AUTOSSH_BIN="$(command -v autossh || command -v ssh)"
fi

# Check if port is already listening and responsive
if lsof -i :$PORT >/dev/null 2>&1; then
  if curl -s --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Tunnel on port ${PORT} is already active and healthy."
    exit 0
  else
    echo "Port ${PORT} is in use but unresponsive. Killing stale processes..."
    lsof -ti :$PORT | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
fi

echo "Starting autossh tunnel to ${TARGET_HOST} (Hindsight :18925, GrowthBook :3200, Postgres :15432)..."
export AUTOSSH_GATETIME=0
exec "$AUTOSSH_BIN" -M 0 -N \
  -o "ServerAliveInterval 15" \
  -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -o "StrictHostKeyChecking accept-new" \
  -L "18925:127.0.0.1:18925" \
  -L "3200:127.0.0.1:3200" \
  -L "15432:127.0.0.1:5432" \
  "$TARGET_HOST"
