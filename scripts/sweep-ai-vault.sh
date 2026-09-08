#!/usr/bin/env bash
set -euo pipefail

export PATH="/Users/benpollack/.nvm/versions/node/v24.12.0/bin:/Users/benpollack/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "=== [$(date)] Starting incremental AI Vault pull ==="
ai-vault backup claude --only-new -y || true
ai-vault backup chatgpt --only-new --random-delay -y || true
echo "=== [$(date)] AI Vault incremental pull complete ==="
