#!/usr/bin/env bash
# _orch/bootstrap.sh — start (or reuse) the orchestrator session, launch the master
# Claude with its role, apply the HUD, and start the background loops.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

S="$SESSION_NAME"
proj="${PROJECT_ROOT:-$(pwd)}"

for dep in tmux jq claude perl git; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep"; exit 1; }
done

rm -f "$STATE_DIR/.stop"
mkdir -p "$WORKERS_DIR"

if ! tmux has-session -t "$S" 2>/dev/null; then
  tmux new-session -d -s "$S" -n "$ORCH_WINDOW" -c "$proj"

  # Session-scoped HUD + activity flags (does NOT touch your global tmux config).
  tmux set-option        -t "$S" status-interval 5
  tmux set-option        -t "$S" status-right-length 160
  tmux set-option        -t "$S" status-right "#($here/hud.sh)  #[fg=cyan]$S#[default] %H:%M"
  tmux set-window-option -t "$S:$ORCH_WINDOW" monitor-activity on
  tmux set-option        -t "$S" visual-activity off
  tmux set-window-option -t "$S:$ORCH_WINDOW" window-status-activity-style "fg=yellow,bold"

  # Launch the master and give it its role (cwd-independent).
  tmux send-keys -t "$S:$ORCH_WINDOW" "claude" Enter
  if wait_ready "$S:$ORCH_WINDOW" 90; then
    send_prompt "$S:$ORCH_WINDOW" "You are the ORCHESTRATOR for this project. First read the file $here/CLAUDE.md and follow it exactly. Your control CLI is $ORCH_ROOT/orch (e.g. '$ORCH_ROOT/orch spawn w1 sonnet \"task\"', '$ORCH_ROOT/orch status', '$ORCH_ROOT/orch send w1 \"msg\"'). Worker completion and blocked events arrive automatically, prefixed [orchestrator heartbeat]. Acknowledge briefly, then wait for my tasks."
  else
    log "master not ready in 90s; open the window and read $here/CLAUDE.md manually"
  fi
  log "session $S created"
else
  echo "session '$S' already exists; reusing"
fi

# Background heartbeat
if [ ! -f "$STATE_DIR/heartbeat.pid" ] || ! kill -0 "$(cat "$STATE_DIR/heartbeat.pid" 2>/dev/null)" 2>/dev/null; then
  nohup "$here/heartbeat.sh" >>"$STATE_DIR/heartbeat.log" 2>&1 &
  echo $! > "$STATE_DIR/heartbeat.pid"
  log "heartbeat pid $(cat "$STATE_DIR/heartbeat.pid")"
fi

# Background watchdog (if enabled)
if jq -e '.watchdog.enabled // true' "$here/config.json" >/dev/null 2>&1; then
  if [ ! -f "$STATE_DIR/watchdog.pid" ] || ! kill -0 "$(cat "$STATE_DIR/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
    nohup "$here/watchdog.sh" >>"$STATE_DIR/watchdog.log" 2>&1 &
    echo $! > "$STATE_DIR/watchdog.pid"
    log "watchdog pid $(cat "$STATE_DIR/watchdog.pid")"
  fi
fi

echo "orchestrator up. attach with:  tmux attach -t $S"
