#!/usr/bin/env bash
#
# test.sh -- runs the test lanes. Every workflow (coach, trial outbox, chat export ->
# voice -> archive, helpers, status) has end-to-end tests in each lane.
#
#   light   Tests/LightTests    Fixtures and stand-ins only: no network, no live
#                               screenpipe, no Bluetooth, no launchd. The whole lane
#                               (tests, not the build) must finish in under 60 s.
#                               Runs on every commit (.githooks/pre-commit).
#   medium  Tests/MediumTests   Real child processes, the built app binary, local
#                               stand-in servers, real timeouts. 60-180 s.
#                               Runs before every push (.githooks/pre-push).
#   heavy   Tests/HeavyTests    The live machine: screenpipe on :3030, ai-vault and
#                               its logins, learner-server, the Pavlok if paired.
#                               3+ min. Runs before every push. A suite skips (with
#                               a reason) when its dependency is missing. Anything
#                               that would stop the owner's real recording stack also
#                               needs LEARNER_HEAVY_DESTRUCTIVE=1.
#
# Usage: scripts/test.sh [light|medium|heavy|all] [extra swift test args]
# Hooks: git config core.hooksPath .githooks   (scripts/install-hooks.sh does this)
#
set -uo pipefail
cd "$(dirname "$0")/.."

LANE="${1:-light}"
[ $# -gt 0 ] && shift

# Lane budgets in seconds (test time, after the build): min, max. 0 = no limit.
budget() {
  case "$1" in
    light)  echo "0 60" ;;
    medium) echo "0 180" ;;
    heavy)  echo "0 0" ;;
  esac
}

run_lane() {
  local lane="$1"; shift
  local target
  target="$(tr '[:lower:]' '[:upper:]' <<< "${lane:0:1}")${lane:1}Tests"
  printf '\n\033[1m==> %s lane (%s)\033[0m\n' "$lane" "$target"
  # Build first so the budget measures the tests, not the compiler.
  swift build --build-tests >/dev/null || { echo "build failed"; swift build --build-tests 2>&1 | grep -E "error" | head -20; return 1; }
  local start end took status
  start=$(date +%s)
  if [ "$lane" = heavy ]; then
    export LEARNER_HEAVY=1
  else
    # Light and medium never see the real app data or ai-vault export.
    local sandbox
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/learner-${lane}.XXXXXX")"
    export LEARNER_DATA_DIR="$sandbox/data" AI_VAULT_DATA="$sandbox/ai-vault-data"
    mkdir -p "$LEARNER_DATA_DIR" "$AI_VAULT_DATA"
    trap 'rm -rf "$sandbox"' RETURN
  fi
  # Medium and heavy run one test at a time: they start real processes and servers, and
  # running dozens at once makes timing tests flaky. Light stays parallel.
  local parallel=()
  [ "$lane" != light ] && parallel=(--no-parallel)
  swift test --skip-build --filter "$target" ${parallel[@]+"${parallel[@]}"} "$@"
  status=$?
  end=$(date +%s)
  took=$((end - start))
  read -r _ max <<< "$(budget "$lane")"
  printf '\033[1m<== %s lane: %s in %ss\033[0m\n' "$lane" "$([ $status -eq 0 ] && echo passed || echo FAILED)" "$took"
  if [ "$status" -eq 0 ] && [ "$max" -gt 0 ] && [ "$took" -gt "$max" ]; then
    echo "The $lane lane took ${took}s; its budget is ${max}s. Move slow tests to a heavier lane."
    return 1
  fi
  return $status
}

case "$LANE" in
  light|medium|heavy) run_lane "$LANE" "$@" ;;
  all) run_lane light "$@" && run_lane medium "$@" && run_lane heavy "$@" ;;
  *) echo "usage: $0 [light|medium|heavy|all]"; exit 2 ;;
esac
