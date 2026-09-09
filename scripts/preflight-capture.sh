#!/usr/bin/env bash
#
# preflight-capture.sh — verify the capture stack still measures what the experiment assumes.
#
# Why this exists: the settings this experiment depends on can revert without anything
# announcing it. TranscriptionMode::Batch is the #[default] in screenpipe's source, so a
# settings reset, a migration or a reinstall silently reintroduces up to 2 minutes of
# deferred transcription — which is what corrupted the 2026-09-08 data. Nothing errors;
# the warning just fires late and turn timing goes quietly wrong.
#
# It checks live state against config/screenpipe-settings.json (the committed expectation),
# so a deliberate change is recorded in git instead of breaking this check forever.
#
# Exit: 0 all good, 1 drift detected, 2 screenpipe unreachable.
#
# Usage:
#   ./scripts/preflight-capture.sh
#   ./scripts/preflight-capture.sh --quiet    # only print problems
#
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="${PREFLIGHT_EXPECTED:-${REPO}/config/screenpipe-settings.json}"
STORE="${HOME}/.screenpipe/store.bin"
API="${SCREENPIPE_API:-http://localhost:3030}"

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PROBLEMS=0
ok()   { [ "$QUIET" -eq 1 ] || printf '    \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
note() { [ "$QUIET" -eq 1 ] || printf '    %s\n' "$*"; }
say()  { [ "$QUIET" -eq 1 ] || printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- settings drift
say "Capture settings"

if [ ! -f "$STORE" ]; then
  bad "screenpipe settings not found at ${STORE}"
else
  # Compare each committed setting against the live store. Keys absent from the
  # committed file are not checked; redacted values are skipped.
  DRIFT="$(python3 - "$STORE" "$EXPECTED" <<'PY'
import json, sys
store, expected = sys.argv[1], sys.argv[2]
try:
    live = json.load(open(store)).get("settings", {})
except Exception as exc:
    print(f"UNREADABLE\tstore.bin\t{exc}\t"); sys.exit(0)
try:
    want = json.load(open(expected)).get("settings", {})
except Exception as exc:
    print(f"UNREADABLE\texpectations\t{exc}\t"); sys.exit(0)
for key in sorted(want):
    w = want[key]
    if w == "***REDACTED***":
        continue
    got = live.get(key, "<missing>")
    status = "OK" if got == w else "DRIFT"
    print(f"{status}\t{key}\t{json.dumps(w)}\t{json.dumps(got)}")
PY
)"
  while IFS=$'\t' read -r status key want got; do
    [ -z "${status:-}" ] && continue
    case "$status" in
      OK)         ok "${key} = ${got}" ;;
      DRIFT)      bad "${key}: expected ${want}, found ${got}" ;;
      UNREADABLE) bad "${key}: ${want}" ;;
    esac
  done <<< "$DRIFT"
fi

# ------------------------------------------------------------------ live pipeline
say "Live pipeline"

HEALTH="$(curl -s --max-time 5 "${API}/health" 2>/dev/null)"
if [ -z "$HEALTH" ]; then
  bad "screenpipe is not answering on ${API} — nothing is being captured"
  say "Result"
  printf '    \033[31m%d problem(s); capture stack is NOT ready\033[0m\n' "$((PROBLEMS+0))"
  exit 2
fi

VERSION="$(printf '%s' "$HEALTH" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
STATUS="$(printf '%s' "$HEALTH" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"
[ -n "$VERSION" ] && note "screenpipe engine version ${VERSION} (stamped onto every turn as metadata.screenpipe_version)"
if [ "$STATUS" = "healthy" ]; then ok "health: ${STATUS}"; else bad "health: ${STATUS:-unknown}"; fi

# The menu-bar app polls these exact columns; if a screenpipe upgrade changes them the
# app stops seeing rows and turn logging silently stops rather than erroring.
ROWS="$(curl -s --max-time 6 -X POST "${API}/raw_sql" -H 'Content-Type: application/json' \
  -d '{"query":"SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 1;"}' 2>/dev/null)"
if printf '%s' "$ROWS" | grep -q '"error"'; then
  bad "the /raw_sql shape the app polls no longer works: $(printf '%s' "$ROWS" | head -c 160)"
elif printf '%s' "$ROWS" | grep -q '"start_time"'; then
  ok "/raw_sql still returns the columns the app polls"
elif [ "$ROWS" = "[]" ]; then
  note "! /raw_sql works but returned no rows yet (nothing transcribed since start)"
else
  bad "unexpected /raw_sql response: $(printf '%s' "$ROWS" | head -c 160)"
fi

# ------------------------------------------------------------------------- result
say "Result"
if [ "$PROBLEMS" -eq 0 ]; then
  [ "$QUIET" -eq 1 ] || printf '    \033[32mcapture stack matches the experiment'"'"'s assumptions\033[0m\n'
  exit 0
fi
printf '    \033[31m%d problem(s) — turn timing may not mean what the experiment assumes\033[0m\n' "$PROBLEMS"
exit 1
