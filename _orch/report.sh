#!/usr/bin/env bash
# _orch/report.sh <worker-id> <event> [--hook]
# Invoked by a worker's Stop / Notification / SubagentStop / UserPromptSubmit hook.
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
log_event="" # event name written to the logs; defaults to $event
to_inbox=1
if [ "${3:-}" = "--hook" ] && [ "$event" = "done" ]; then
  # Bounded read: a hook stdin that never reaches EOF must not hang the worker's turn.
  # bash's own read -t (not coreutils timeout, absent on stock macOS); it returns
  # non-zero at EOF/timeout, which is expected — whatever arrived is in $payload.
  payload=""
  IFS= read -r -d '' -t 5 payload 2>/dev/null || true
  # Only real arrays count (a string/number/object is not a task list), and entries
  # whose status is explicitly terminal are ignored; unknown statuses count as live
  # (the watchdog's background_wait backstop still surfaces them).
  # shellcheck disable=SC2016
  bg_filter='def live: [ (.[]? // empty)
      | select((type != "object") or (((.status // "") | tostring | ascii_downcase)
          | . as $st | ["completed","complete","done","finished","failed","error","killed","stopped","cancelled","canceled","exited"]
          | map(. == $st) | any | not)) ];
    (type == "object")
    and ((((.background_tasks | arrays) // []) | live | length > 0)
      or (((.session_crons | arrays) // []) | live | length > 0))'
  if printf '%s' "$payload" | jq -e "$bg_filter" >/dev/null 2>&1; then
    # Turn ended with background work still live: log it, but don't wake the master.
    event="waiting-bg"; log_event="turn-ended"; to_inbox=0
  fi
fi

# issue #204 (d): UserPromptSubmit hook. A positive "claude is taking prompts" signal that
# recovers ONLY a spawn-failed worker (hand-answered dialog, task re-sent) to working, so
# live_worker_count and the root-dirty watch see it before its first Stop. Every other
# status is left exactly as is; no inbox/events line (it fires on every prompt) and no
# status file is ever created for an unknown id.
if [ "$event" = "prompt-submitted" ]; then
  f="$WORKERS_DIR/$id.json"
  # shellcheck disable=SC2016  # jq filter; $t is a jq --arg var
  [ -f "$f" ] && update_worker_status "$id" --arg t "$ts" \
    'if .status == "spawn-failed" then .status = "working" | .updated = $t else . end' || true
  exit 0
fi

line="$(printf '{"id":"%s","event":"%s","ts":"%s"}' "$id" "${log_event:-$event}" "$ts")"
[ "$to_inbox" = 1 ] && printf '%s\n' "$line" >> "$INBOX"
printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"

# shellcheck disable=SC2016  # jq filter in single quotes; $id/$s/$t are jq --arg vars, not shell
# A SubagentStop (e.g. a background agent finishing after the turn) only refines an
# in-progress status. It must not overwrite waiting-bg (issue #163) nor a status that
# drives a consumer -- done (--after deps, reap), needs-input (re-alert), dead/merged/
# blocked/spawn-failed -- since subagent-done is only watched like "working" (stall +
# dead sweep), never reaped, and would leave dependents queued forever.
# (No jq IN(): it is jq >= 1.6, and a compile error here would drop every status write.)
update_worker_status "$id" --arg id "$id" --arg s "$event" --arg t "$ts" \
  '.id = (.id // $id)
   | .status = (if $s == "subagent-done"
                   and ((.status // "") as $cur
                        | ["waiting-bg","done","needs-input","dead","merged","blocked","spawn-failed"]
                        | map(. == $cur) | any)
                then .status else $s end)
   | .updated=$t' || true
exit 0
