#!/usr/bin/env bash
#
# test.sh — the whole test runner. No pytest, no dependencies, stdlib unittest only.
#
# Two lanes:
#
#   fast   tests/*.py            Pure and hermetic: no network, no database, no
#                                launchd, no .docx corpus, no Swift compile. The
#                                capture-script tests run the real shell scripts
#                                but with every state-changing command stubbed on
#                                PATH and HOME pointed at a throwaway directory.
#                                Run this on every change.
#
#          tests/ts/*.test.ts    Also in the fast lane: `bun test tests/ts` (parser,
#                                RPC client against a local mock server, baseline
#                                mapping). Skipped with a note when bun is missing.
#                                The ai-vault parser suite also reads ~/ai-vault-data
#                                when it exists (read-only) and skips otherwise.
#
#   heavy  tests/heavy/*.py      Needs the real world: screenpipe on :3030, the
#                                209-file .docx corpus, swiftc. Opt-in; each suite
#                                skips rather than fails when its dependency is
#                                missing. Sets AIAGG_HEAVY=1 for you.
#
# The destructive live capture-stack cycle (tests/heavy/test_capture_scripts_live.py)
# stays skipped even in the heavy lane unless you also export
# AIAGG_HEAVY_DESTRUCTIVE=1. It stops the owner's real recording stack.
#
# Usage:
#   ./scripts/test.sh              # fast (default)
#   ./scripts/test.sh fast
#   ./scripts/test.sh heavy
#   ./scripts/test.sh all
#   ./scripts/test.sh fast -v      # extra args pass through to unittest
#
set -uo pipefail

cd "$(dirname "$0")/.."

LANE="${1:-fast}"
[ $# -gt 0 ] && shift

# unittest discovery only recurses into subdirectories that are importable
# packages, which is why `-s tests` does not pick up tests/heavy. Do NOT add
# tests/heavy/__init__.py -- the heavy lane would then run on every change.
run_lane() {
  local name="$1" dir="$2"; shift 2
  printf '\n\033[1m==> %s lane (%s)\033[0m\n' "$name" "$dir"
  python3 -m unittest discover -s "$dir" -p 'test_*.py' "$@"
}

# The TypeScript half of the fast lane. Extra args are unittest's, so not passed on.
run_ts_lane() {
  printf '\n\033[1m==> fast lane (tests/ts, bun)\033[0m\n'
  local bun_bin
  bun_bin="$(command -v bun || true)"
  [ -z "$bun_bin" ] && [ -x "${HOME}/.bun/bin/bun" ] && bun_bin="${HOME}/.bun/bin/bun"
  if [ -z "$bun_bin" ]; then
    echo "bun not found; skipping tests/ts"
    return 0
  fi
  "$bun_bin" test tests/ts
}

case "$LANE" in
  fast)
    run_lane fast tests "$@"; py=$?
    run_ts_lane; ts=$?
    [ "$py" -eq 0 ] && [ "$ts" -eq 0 ]
    ;;
  heavy)
    export AIAGG_HEAVY=1
    run_lane heavy tests/heavy "$@"
    ;;
  all)
    run_lane fast tests "$@" || exit $?
    run_ts_lane || exit $?
    export AIAGG_HEAVY=1
    run_lane heavy tests/heavy "$@"
    ;;
  -h|--help)
    sed -n '2,30p' "$0"; exit 0
    ;;
  *)
    echo "unknown lane: ${LANE} (expected fast, heavy or all)" >&2
    exit 2
    ;;
esac
