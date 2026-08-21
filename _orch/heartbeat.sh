#!/usr/bin/env bash
# _orch/heartbeat.sh — cheap external loop. Watches the inbox and wakes the master
# ONLY when there is a decision to make. The LLM never polls; bash does.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

# Atomically claim the current inbox by renaming it aside, then fold it into the
# pending-batch file. This closes the lost-events race (issue #10): the old
# `events="$(cat "$INBOX")"; : > "$INBOX"` read-then-truncate dropped any event a
# worker hook appended between the read and the truncate. Workers append with
# `>> "$INBOX"` (open-by-path), so once the inbox is renamed aside their appends
# open a brand-new inbox and can never fall into a truncation gap.
#
# Prints the pending-batch path on stdout when a batch is pending (either freshly
# claimed or left over from a crashed drain); returns non-zero and prints nothing
# when there is nothing to drain. `$INBOX` not existing yet is handled.
inbox_swap() { # -> echoes "$INBOX.processing" when a batch is pending
  local proc="$INBOX.processing" claim="$INBOX.claiming"
  if [ -e "$INBOX" ]; then
    # Atomic claim. After this rename, concurrent `>> "$INBOX"` appends open a
    # fresh inbox; nothing they write can land in the batch we just claimed.
    if mv "$INBOX" "$claim" 2>/dev/null; then
      # Fold the claimed batch into the pending file. Both are dead files no
      # worker ever opens, so this append is race-free. Appending (rather than
      # overwriting) preserves any batch orphaned by a crashed earlier drain.
      cat "$claim" >> "$proc" && rm -f "$claim"
    fi
  fi
  [ -s "$proc" ] || { rm -f "$proc" 2>/dev/null; return 1; }
  printf '%s\n' "$proc"
}

# Drain the inbox atomically. Prints all pending events on stdout and returns 0
# when there were events; returns non-zero and prints nothing when the inbox was
# empty or absent.
drain_inbox() {
  local proc
  proc="$(inbox_swap)" || return 1
  cat "$proc"
  rm -f "$proc"
}

# Turn a drained batch (one raw JSON event line per event, as produced by
# drain_inbox) into a single terse inject line, e.g.
# "[orch] w1 done · w2 needs-input x3". Honors `heartbeat.inject_denylist`
# in config.json (default ["subagent-done"]) as a DENYLIST, never an
# allowlist: only event types named there are dropped from the summary, so
# any new event type introduced later always surfaces instead of being
# silently swallowed forever. Repeats of the same (id,event) collapse into
# one item with an "xN" count. Prints the line and returns 0 when at least
# one non-denylisted event is present; prints nothing and returns 1 when
# the whole batch is denylisted-only, i.e. there is nothing actionable —
# callers use that failure to skip send_prompt entirely (issue #122).
#
# events.jsonl (the durable log) is untouched by this: report.sh/watchdog.sh/
# spawn.sh tee every event there before it ever reaches drain_inbox, so
# nothing summarized or dropped here affects that record.
summarize_events() { # <events>
  local events="$1" denylist_json line
  denylist_json="$(jq -c '.heartbeat.inject_denylist // ["subagent-done"]' "$CONFIG")"

  local -A counts=()
  local -a order=()
  local id event key
  while IFS=$'\t' read -r id event; do
    [ -n "$id" ] || continue
    key="$id"$'\x1f'"$event"
    if [ -z "${counts[$key]:-}" ]; then
      order+=("$key")
      counts[$key]=0
    fi
    counts[$key]=$((counts[$key] + 1))
  done < <(printf '%s\n' "$events" | jq -r --argjson deny "$denylist_json" '
    select(.id != null and .event != null) |
    . as $ev |
    select(($deny | index($ev.event)) | not) |
    "\(.id)\t\(.event)"
  ' 2>/dev/null)

  [ "${#order[@]}" -gt 0 ] || return 1

  local out="" k id2 event2 count item
  for k in "${order[@]}"; do
    id2="${k%%$'\x1f'*}"
    event2="${k#*$'\x1f'}"
    count="${counts[$k]}"
    item="$id2 $event2"
    [ "$count" -gt 1 ] && item="$item x$count"
    if [ -z "$out" ]; then out="$item"; else out="$out · $item"; fi
  done

  printf '[orch] %s' "$out"
}

# Status of worker <id>, or empty if its status file doesn't exist yet.
_worker_status() { # <id>
  local f="$WORKERS_DIR/$1.json"
  [ -f "$f" ] && jq -r '.status // empty' "$f" 2>/dev/null
}

# Task dependencies (issue #22): pop the first queue item whose `after` worker
# (if any) has reached "done", without disturbing the relative order of the
# items behind it. A dependency-less item is always eligible. Prints the item
# and rewrites the queue file minus that one line; returns 1 (no output, queue
# untouched) if the queue is empty or nothing in it is ready yet.
queue_pop_ready() {
  [ -s "$QUEUE" ] || return 1
  local line after found="" tmp="$QUEUE.tmp.$$"
  : > "$tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$found" ]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    after="$(jq -r '.after // empty' <<<"$line")"
    if [ -z "$after" ] || [ "$(_worker_status "$after")" = "done" ]; then
      found="$line"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Drain one pending spawn from the queue (issues #21/#31/#24, #22 task deps) if
# the unified resource gate now allows it AND at least one queued item's
# dependency (if any) is satisfied — e.g. a worker just freed a concurrency slot
# or a dependency worker just reported "done". Re-checks the gate itself, so
# it's safe to call every tick.
drain_queue_if_room() {
  [ -s "$QUEUE" ] || return 0
  if ! check_spawn_gate; then
    log "queue drain: still blocked ($GATE_REASON)"
    return 0
  fi
  local item id model task mode resume allow
  item="$(queue_pop_ready)" || return 0
  id="$(jq -r '.id' <<<"$item")"
  model="$(jq -r '.model' <<<"$item")"
  task="$(jq -r '.task' <<<"$item")"
  mode="$(jq -r '.mode' <<<"$item")"
  resume="$(jq -r '.resume' <<<"$item")"
  allow="$(jq -r '.allow_csv' <<<"$item")"

  local args=("$id" "$model" "$task")
  [ "$mode" = "--no-worktree" ] && args+=(--no-worktree)
  if [ -n "$resume" ]; then
    local rargs=(); read -ra rargs <<< "$resume"
    args+=("${rargs[@]}")
  fi
  [ -n "$allow" ] && args+=(--allow "$allow")

  log "queue drain: spawning queued worker $id"
  "$here/spawn.sh" "${args[@]}" >> "$LOG" 2>&1 &
}

# --- Master-liveness alert (issue #15) -----------------------------------------
# wait_ready only ever polls a pane's CONTENT, so a dead/absent master window (the
# tmux session killed, the window closed, the pane's process gone) looks
# indistinguishable from "just busy": is_ready keeps returning false, the events
# get requeued, and the loop retries forever with nothing ever telling anyone the
# master is gone. Detect the window's existence directly and surface it via log()
# instead of silently requeuing — heartbeat has no other channel once the master
# itself is the thing that's dead.
master_window_alive() { # <session:window> -> 0 if that tmux window exists
  tmux capture-pane -t "$1" -p >/dev/null 2>&1
}

# $STATE_DIR/.master-dead holds "<first-seen-ts>\n<last-alert-ts>" so the alert
# re-fires on an interval instead of firing exactly once (and getting missed) or
# spamming the log every tick.
master_dead_alert() { # <target> <now> <interval_s>
  local target="$1" now="$2" interval="$3"
  local mf="$STATE_DIR/.master-dead" first="$now" last=0
  if [ -f "$mf" ]; then
    { IFS= read -r first; IFS= read -r last; } < "$mf" || true
    : "${first:=$now}"; : "${last:=0}"
  fi
  if [ "$last" -eq 0 ] || [ "$((now - last))" -ge "$interval" ]; then
    log "ALERT: master window '$target' is not alive (down $((now - first))s); worker events cannot be delivered — attach tmux and re-run bootstrap.sh"
    last="$now"
  fi
  printf '%s\n%s\n' "$first" "$last" > "$mf"
}

# Drop the standing alert once the master window is back.
master_dead_clear() { rm -f "$STATE_DIR/.master-dead"; }

heartbeat_main() {
  local S="$SESSION_NAME"
  # $CONFIG (from lib.sh) honors ORCH_ROOT overrides, unlike a script-relative
  # path — needed so hermetic tests can point config at a temp dir.
  local normal idle events
  normal="$(jq -r '.intervals.normal_seconds // 20' "$CONFIG")"
  idle="$(jq -r '.intervals.idle_seconds // 60' "$CONFIG")"
  local master_alert_interval
  master_alert_interval="$(jq -r '.heartbeat.master_alert_interval_seconds // 60' "$CONFIG")"

  # Issue #52 safety valve: pane_has_draft() is a best-effort heuristic, so a
  # single misdetection (or a genuinely long-lived operator draft) must never be
  # able to starve delivery forever. Once EITHER bound trips — N consecutive
  # draft-ticks or T seconds since the first one — force-deliver regardless.
  local max_draft_ticks max_draft_secs draft_requeue_count=0 draft_requeue_since=0
  max_draft_ticks="$(jq -r '.heartbeat.max_draft_requeue_ticks // 10' "$CONFIG")"
  max_draft_secs="$(jq -r '.heartbeat.max_draft_requeue_seconds // 300' "$CONFIG")"

  # Issue #91: read the self-update knobs ONCE here (like normal/idle above),
  # not per-tick — the loop below only needs a cheap mtime check, not a fresh
  # config read every 20s. `enabled` reads the raw value because jq's
  # `// default` treats literal `false` as absent (same trap update.sh's own
  # _cfg avoids); a config that can't be parsed at all fails closed (disabled).
  local upd_enabled=0 upd_interval_min=1440 upd_state _upd_e _upd_h
  if _upd_e="$(jq -r '.update.enabled' "$CONFIG" 2>/dev/null)"; then
    [ "$_upd_e" = "false" ] || upd_enabled=1
    _upd_h="$(jq -r '.update.interval_hours' "$CONFIG" 2>/dev/null)"
    case "$_upd_h" in ''|null|*[!0-9]*) ;; *) upd_interval_min=$(( _upd_h * 60 )) ;; esac
  fi

  : > "$INBOX"
  log "heartbeat start (session=$S)"

  while [ ! -f "$STATE_DIR/.stop" ]; do
    drain_queue_if_room

    # Issue #91: throttled (>=24h apart, see update.* in config.json), notify-only
    # self-update check. The default tick is 20s (~4,300/day), so most ticks
    # must cost NEXT TO NOTHING: `upd_enabled` is read once above (not here),
    # and when due, "due" itself is a single cheap `find -mmin` mtime check —
    # only when that says the window has actually elapsed do we pay for
    # forking the full update.sh (source lib.sh, config reads, network).
    # update.sh re-checks the throttle itself too (its own tests call
    # --daily-check directly, not through this loop, and must stay correct
    # standalone) — this is purely a cheap pre-filter, not a second source of
    # truth. Skipped under bats (same $BATS_TEST_FILENAME convention as
    # lib.sh's isolation guard): any test that sources/runs heartbeat_main
    # with a config carrying update.enabled=true (e.g. a fixture copied from
    # the real config.json) must never make a real network call.
    if [ "$upd_enabled" = 1 ] && [ -z "${BATS_TEST_FILENAME:-}" ]; then
      upd_state="$STATE_DIR/update-check.json"
      if [ ! -f "$upd_state" ] || [ -z "$(find "$upd_state" -mmin -"$upd_interval_min" 2>/dev/null)" ]; then
        "$here/update.sh" --daily-check >/dev/null 2>&1 || true
      fi
    fi

    if master_window_alive "$S:$ORCH_WINDOW"; then
      master_dead_clear
    else
      master_dead_alert "$S:$ORCH_WINDOW" "$(date +%s)" "$master_alert_interval"
    fi

    if events="$(drain_inbox)"; then
      local summary
      if ! summary="$(summarize_events "$events")"; then
        # Issue #122: the whole batch was denylist-only (e.g. a run of
        # subagent-done) — nothing actionable, so skip send_prompt entirely.
        # No wake, no orchestrator turn, no tokens spent. events.jsonl already
        # has every event durably (report.sh/watchdog.sh/spawn.sh tee there
        # before drain_inbox ever sees it), so nothing is lost by not requeuing.
        log "heartbeat: no actionable events, not waking master ($(echo "$events" | tr '\n' ' '))"
      elif ! master_window_alive "$S:$ORCH_WINDOW"; then
        # Master window is gone outright — wait_ready would just poll a dead
        # target until its own timeout every tick. Requeue and move on instead
        # of burning that timeout; master_dead_alert above already surfaced it.
        printf '%s\n' "$events" >> "$INBOX"
        log "master window down; requeued events"
      # Only poke the master when ITS pane is idle, to avoid prompt collisions.
      elif ! wait_ready "$S:$ORCH_WINDOW" 45; then
        # Master busy — requeue and try again next tick.
        printf '%s\n' "$events" >> "$INBOX"
        log "master busy; requeued events"
      else
        # Issue #38: an idle-looking input box can still hold the operator's
        # unsent draft. Injecting here would paste into it and submit it via the
        # Enter in send_prompt, wiping the draft. Requeue instead of injecting —
        # never clear the line — and retry next tick. But (issue #52) never do
        # that forever: force-deliver once the safety valve trips.
        local force_deliver=0 elapsed=0
        if pane_has_draft "$S:$ORCH_WINDOW"; then
          draft_requeue_count=$((draft_requeue_count + 1))
          [ "$draft_requeue_since" -gt 0 ] || draft_requeue_since="$(date +%s)"
          elapsed=$(( $(date +%s) - draft_requeue_since ))
          if [ "$draft_requeue_count" -ge "$max_draft_ticks" ] || [ "$elapsed" -ge "$max_draft_secs" ]; then
            force_deliver=1
            log "draft safety valve tripped (ticks=$draft_requeue_count elapsed=${elapsed}s >= ticks_cap=$max_draft_ticks/secs_cap=$max_draft_secs); forcing delivery"
          fi
        else
          force_deliver=1
        fi

        if [ "$force_deliver" -eq 1 ]; then
          draft_requeue_count=0
          draft_requeue_since=0
          send_prompt "$S:$ORCH_WINDOW" "$summary"
          log "woke master with: $summary"
        else
          printf '%s\n' "$events" >> "$INBOX"
          log "master has an unsent draft; requeued events (${draft_requeue_count}/${max_draft_ticks})"
        fi
      fi
      sleep "$normal"
    else
      sleep "$idle"
    fi
  done
  log "heartbeat stop"
}

# Run the loop only when executed directly. When sourced (e.g. by hermetic bats
# tests) this exposes inbox_swap/drain_inbox without starting the loop.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_valid_session_name
  heartbeat_main
fi
