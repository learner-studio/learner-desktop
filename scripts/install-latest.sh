#!/usr/bin/env bash
#
# install-latest.sh -- installs on this Mac the app that CI built and tested, without
# compiling or testing anything here. It takes the newest CI run on main that passed
# every phase, downloads that run's "learner-desktop-app" artifact (the exact bundle the
# runner installed and tested), re-signs it with this Mac's Apple Development identity (so
# macOS keeps the app's microphone, speech and Bluetooth grants) and installs it through
# scripts/build-app.sh (LEARNER_APP_BUNDLE).
#
#   scripts/install-latest.sh            the newest green run on main
#   RUN_ID=<id> scripts/install-latest.sh   that run instead (it must have passed)
#   FORCE=1 ...                          reinstall even if that commit is already installed
#
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
STAMP="${HOME}/.ai-aggregator/installed-build.txt"

if [ -n "${RUN_ID:-}" ]; then
  read -r run sha conclusion < <(gh run view "$RUN_ID" -R "$REPO" --json databaseId,headSha,conclusion -q '"\(.databaseId) \(.headSha) \(.conclusion)"')
  [ "$conclusion" = success ] || { echo "run $RUN_ID did not pass (conclusion: ${conclusion:-none}); not installing it" >&2; exit 1; }
else
  read -r run sha < <(gh run list -R "$REPO" --workflow ci.yml --branch main --event push --status success -L 1 \
    --json databaseId,headSha -q '.[0] | "\(.databaseId) \(.headSha)"')
  [ -n "${run:-}" ] || { echo "no passing CI run on main yet" >&2; exit 1; }
fi
echo "CI run ${run} passed for commit ${sha:0:7}: https://github.com/${REPO}/actions/runs/${run}"

if [ "${FORCE:-0}" != 1 ] && [ -f "$STAMP" ] && grep -qx "commit ${sha}" "$STAMP"; then
  echo "commit ${sha:0:7} is already installed (FORCE=1 reinstalls)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/learner-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
gh run download "$run" -R "$REPO" -n learner-desktop-app -D "$work/artifact"
grep -qx "commit ${sha}" "$work/artifact/BUILD.txt" || {
  echo "the artifact's BUILD.txt does not name commit ${sha}:" >&2; cat "$work/artifact/BUILD.txt" >&2; exit 1; }
ditto -x -k "$work/artifact/Learner-Desktop.zip" "$work/unpacked"

LEARNER_APP_BUNDLE="$work/unpacked/Learner Desktop.app" OUT_DIR="$work/bundle" scripts/build-app.sh

mkdir -p "$(dirname "$STAMP")"
{ cat "$work/artifact/BUILD.txt"; echo "installed $(date -u +%FT%TZ)"; } > "$STAMP"
echo "Installed commit ${sha:0:7} from CI run ${run}."
