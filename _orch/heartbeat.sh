#!/usr/bin/env bash
# _orch/heartbeat.sh — cheap external loop. Watches the inbox and wakes the master
# ONLY when there is a decision to make. The LLM never polls; bash does.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

S="$SESSION_NAME"
cfg="$here/config.json"
normal="$(jq -r '.intervals.normal_seconds // 20' "$cfg")"
idle="$(jq -r '.intervals.idle_seconds // 60' "$cfg")"

: > "$INBOX"
log "heartbeat start (session=$S)"

while [ ! -f "$STATE_DIR/.stop" ]; do
  if [ -s "$INBOX" ]; then
    events="$(cat "$INBOX")"; : > "$INBOX"
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
