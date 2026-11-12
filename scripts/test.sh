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
#                               its logins, learner-server, the Pavlok if paired; the
#                               release build and signed bundle; the audio benchmark
#                               through screenpipe's speech-to-text. 3+ min. Runs before every push. A suite skips (with
#                               a reason) when its dependency is missing. Anything
#                               that would stop the owner's real recording stack also
#                               needs LEARNER_HEAVY_DESTRUCTIVE=1.
#
# Usage: scripts/test.sh [light|medium|heavy|all] [extra swift test args]
# Hooks: git config core.hooksPath .githooks   (scripts/install-hooks.sh does this)
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

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
  # Voice ID links sherpa-onnx from local binaries git does not hold.
  if [ ! -d third_party/sherpa-onnx/artifacts/sherpa-onnx.xcframework ]; then
    echo "sherpa-onnx is not fetched: run scripts/fetch-voice-id.sh once (it also fetches Voice ID's model)"; return 1
  fi
  # Build first so the budget measures the tests, not the compiler.
  swift build --build-tests >/dev/null || { echo "build failed"; swift build --build-tests 2>&1 | grep -E "error" | head -20; return 1; }
  local start end took status
  start=$(date +%s)
  if [ "$lane" = heavy ]; then
    export LEARNER_HEAVY=1
    # The heavy lane also checks the app as it ships: a release build, packaged and signed
    # by build-app.sh (Tests/HeavyTests/BundleTests). Built here, so a slow compile does
    # not count against a test's time limit; a failing release build fails the lane.
    echo "building the release binary..."
    swift build -c release --product LearnerDesktop >/dev/null || { echo "release build failed"; swift build -c release --product LearnerDesktop 2>&1 | grep -E "error" | head -20; return 1; }
    export LEARNER_RELEASE_BINARY="$PWD/.build/release/LearnerDesktop"
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
  local out
  out="$(mktemp "${TMPDIR:-/tmp}/learner-${lane}-out.XXXXXX")"
  swift test --skip-build --filter "$target" ${parallel[@]+"${parallel[@]}"} "$@" 2>&1 | tee "$out"
  status=${PIPESTATUS[0]}
  # A live check skipped for an expired login (ChatsLiveTests) is counted and named here:
  # skipped, never passed. It does not fail the lane; everything else still does.
  local skipped
  skipped="$(grep -o '^\*\*\* SKIPPED live check [^:]*' "$out" | sed 's/^\*\*\* SKIPPED live check //' | sort -u)"
  rm -f "$out"
  if [ -n "$skipped" ]; then
    printf '\033[1;33m!!! %s live check(s) SKIPPED, not passed:\033[0m\n' "$(wc -l <<< "$skipped" | tr -d ' ')"
    sed 's/^/!!!   /' <<< "$skipped"
  fi
  end=$(date +%s)
  took=$((end - start))
  read -r _ max <<< "$(budget "$lane")"
  # A shared CI runner (3 slow cores) is not this Mac: its time says nothing about a test.
  if [ "${LEARNER_CI:-0}" = 1 ] && [ "$max" -gt 0 ]; then
    echo "($lane lane: ${took}s; the ${max}s budget is not enforced on a CI runner)"
    max=0
  fi
  printf '\033[1m<== %s lane: %s%s in %ss\033[0m\n' "$lane" "$([ $status -eq 0 ] && echo passed || echo FAILED)" \
    "$([ -n "$skipped" ] && echo " ($(wc -l <<< "$skipped" | tr -d ' ') live check skipped)")" "$took"
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
