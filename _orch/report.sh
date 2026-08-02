#!/usr/bin/env bash
# _orch/report.sh <worker-id> <event>
# Invoked by a worker's Stop / Notification / SubagentStop hook.
# Appends an event to the shared inbox and updates the worker's status file.
# Must always exit 0 so it never blocks the worker's turn.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:-${ORCH_WORKER_ID:-unknown}}"
event="${2:-update}"
ts="$(date -u +%FT%TZ)"

printf '{"id":"%s","event":"%s","ts":"%s"}\n' "$id" "$event" "$ts" >> "$INBOX"

update_worker_status "$id" --arg id "$id" --arg s "$event" --arg t "$ts" \
  '.id = (.id // $id) | .status=$s | .updated=$t' || true
exit 0
