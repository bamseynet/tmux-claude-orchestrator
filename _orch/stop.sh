#!/usr/bin/env bash
# _orch/stop.sh — stop the background loops. Leaves the tmux session running so you
# can inspect workers. Kill the session yourself when done.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

touch "$STATE_DIR/.stop"
for p in heartbeat watchdog; do
  pid="$(cat "$STATE_DIR/$p.pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  rm -f "$STATE_DIR/$p.pid"
done
log "stopped background loops"
echo "stopped heartbeat + watchdog."
echo "session '$SESSION_NAME' still running — kill it with:  tmux kill-session -t $SESSION_NAME"
