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

# Drain one pending spawn from the queue (issues #21/#31/#24) if the unified
# resource gate now allows it — e.g. a worker just freed a concurrency slot by
# reporting "done". Re-checks the gate itself, so it's safe to call every tick.
drain_queue_if_room() {
  [ -s "$QUEUE" ] || return 0
  if ! check_spawn_gate; then
    log "queue drain: still blocked ($GATE_REASON)"
    return 0
  fi
  local item id model task mode resume allow
  item="$(queue_pop)" || return 0
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

  : > "$INBOX"
  log "heartbeat start (session=$S)"

  while [ ! -f "$STATE_DIR/.stop" ]; do
    drain_queue_if_room

    if master_window_alive "$S:$ORCH_WINDOW"; then
      master_dead_clear
    else
      master_dead_alert "$S:$ORCH_WINDOW" "$(date +%s)" "$master_alert_interval"
    fi

    if events="$(drain_inbox)"; then
      if ! master_window_alive "$S:$ORCH_WINDOW"; then
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
          send_prompt "$S:$ORCH_WINDOW" "[orchestrator heartbeat] Worker events since last check:
$events

Read _orch/state/workers/*.json, then decide and dispatch next steps (assign, review, or shut down). If you're at all unsure of current orchestration state (e.g. right after a compaction), run $here/rehydrate.sh first."
          log "woke master with: $(echo "$events" | tr '\n' ' ')"
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
  heartbeat_main
fi
