#!/usr/bin/env bash
#
# install-latest.sh -- installs main's newest CI-tested build on this Mac now, printed to
# the terminal. The same code as the updater (scripts/auto-update.sh --manual), except it
# does not wait for a call to end. RUN_ID=<id> installs that green run; FORCE=1 reinstalls.
set -euo pipefail
exec "$(dirname "$0")/auto-update.sh" --manual
