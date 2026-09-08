#!/usr/bin/env bash
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

echo "Starting autossh tunnel on 127.0.0.1:${PORT} -> ${TARGET_HOST}:${PORT}..."
export AUTOSSH_GATETIME=0
exec "$AUTOSSH_BIN" -M 0 -N \
  -o "ServerAliveInterval 15" \
  -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -o "StrictHostKeyChecking accept-new" \
  -L "${PORT}:127.0.0.1:${PORT}" \
  "$TARGET_HOST"
