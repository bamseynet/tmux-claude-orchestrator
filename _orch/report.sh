#!/usr/bin/env bash
# _orch/report.sh <worker-id> <event> [--hook]
# Invoked by a worker's Stop / Notification / SubagentStop hook.
# Appends an event to the shared inbox and updates the worker's status file.
# With --hook (Stop hook only) the hook JSON on stdin is read: a Stop that still has
# background_tasks / session_crons is "waiting-bg", logged to events.jsonl but not
# the inbox, so the master isn't woken for a turn that isn't finished (issue #163).
# Without --hook stdin is never read (callers may leave it an open tty/pipe).
# Must always exit 0 so it never blocks the worker's turn.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:-${ORCH_WORKER_ID:-unknown}}"
event="${2:-update}"
ts="$(date -u +%FT%TZ)"

# Fail-open: anything but a parseable payload with a non-empty array is a plain event.
if [ "${3:-}" = "--hook" ] && [ "$event" = "done" ]; then
  # Bounded read: a hook stdin that never reaches EOF must not hang the worker's turn.
  if command -v timeout >/dev/null 2>&1; then
    payload="$(timeout 5 cat 2>/dev/null || true)"
  else
    payload="$(cat 2>/dev/null || true)"
  fi
  # Only real arrays count (a string/number/object is not a task list), and entries
  # whose status is explicitly terminal are ignored; unknown statuses count as live
  # (the watchdog's background_wait backstop still surfaces them).
  # shellcheck disable=SC2016
  bg_filter='def live: [ (.[]? // empty)
      | select((type != "object") or (((.status // "") | tostring | ascii_downcase)
          | IN("completed","complete","done","finished","failed","error","killed","stopped","cancelled","canceled","exited") | not)) ];
    (type == "object")
    and ((((.background_tasks | arrays) // []) | live | length > 0)
      or (((.session_crons | arrays) // []) | live | length > 0))'
  if printf '%s' "$payload" | jq -e "$bg_filter" >/dev/null 2>&1; then
    event="waiting-bg"
    line="$(printf '{"id":"%s","event":"turn-ended","ts":"%s"}' "$id" "$ts")"
    printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
    # shellcheck disable=SC2016  # jq vars
    update_worker_status "$id" --arg id "$id" --arg s "$event" --arg t "$ts" \
      '.id = (.id // $id) | .status=$s | .updated=$t' || true
    exit 0
  fi
fi

line="$(printf '{"id":"%s","event":"%s","ts":"%s"}' "$id" "$event" "$ts")"
printf '%s\n' "$line" >> "$INBOX"
printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"

# shellcheck disable=SC2016  # jq filter in single quotes; $id/$s/$t are jq --arg vars, not shell
# A SubagentStop (e.g. a background agent finishing) must not knock a worker out of
# waiting-bg: subagent-done has no watchdog/dead-sweep coverage, so the worker would
# then never be reported (issue #163).
update_worker_status "$id" --arg id "$id" --arg s "$event" --arg t "$ts" \
  '.id = (.id // $id)
   | .status = (if $s == "subagent-done" and .status == "waiting-bg" then .status else $s end)
   | .updated=$t' || true
exit 0
