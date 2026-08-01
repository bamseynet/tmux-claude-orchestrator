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

heartbeat_main() {
  local S="$SESSION_NAME"
  local cfg="$here/config.json"
  local normal idle events
  normal="$(jq -r '.intervals.normal_seconds // 20' "$cfg")"
  idle="$(jq -r '.intervals.idle_seconds // 60' "$cfg")"

  : > "$INBOX"
  log "heartbeat start (session=$S)"

  while [ ! -f "$STATE_DIR/.stop" ]; do
    if events="$(drain_inbox)"; then
      # Only poke the master when ITS pane is idle, to avoid prompt collisions.
      if wait_ready "$S:$ORCH_WINDOW" 45; then
        send_prompt "$S:$ORCH_WINDOW" "[orchestrator heartbeat] Worker events since last check:
$events

Read _orch/state/workers/*.json, then decide and dispatch next steps (assign, review, or shut down)."
        log "woke master with: $(echo "$events" | tr '\n' ' ')"
      else
        # Master busy — requeue and try again next tick.
        printf '%s\n' "$events" >> "$INBOX"
        log "master busy; requeued events"
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
