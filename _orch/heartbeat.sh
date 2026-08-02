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

heartbeat_main() {
  local S="$SESSION_NAME"
  local cfg="$here/config.json"
  local normal idle events
  normal="$(jq -r '.intervals.normal_seconds // 20' "$cfg")"
  idle="$(jq -r '.intervals.idle_seconds // 60' "$cfg")"

  : > "$INBOX"
  log "heartbeat start (session=$S)"

  while [ ! -f "$STATE_DIR/.stop" ]; do
    drain_queue_if_room

    if events="$(drain_inbox)"; then
      # Only poke the master when ITS pane is idle, to avoid prompt collisions.
      if ! wait_ready "$S:$ORCH_WINDOW" 45; then
        # Master busy — requeue and try again next tick.
        printf '%s\n' "$events" >> "$INBOX"
        log "master busy; requeued events"
      elif pane_has_draft "$S:$ORCH_WINDOW"; then
        # Issue #38: an idle-looking input box can still hold the operator's
        # unsent draft. Injecting here would paste into it and submit it via the
        # Enter in send_prompt, wiping the draft. Requeue instead of injecting —
        # never clear the line — and retry next tick.
        printf '%s\n' "$events" >> "$INBOX"
        log "master has an unsent draft; requeued events"
      else
        send_prompt "$S:$ORCH_WINDOW" "[orchestrator heartbeat] Worker events since last check:
$events

Read _orch/state/workers/*.json, then decide and dispatch next steps (assign, review, or shut down)."
        log "woke master with: $(echo "$events" | tr '\n' ' ')"
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
