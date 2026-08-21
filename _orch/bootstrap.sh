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
  command -v "$dep" >/dev/null || { say "missing dependency: $dep"; exit 1; }
done

rm -f "$STATE_DIR/.stop"
mkdir -p "$WORKERS_DIR"

# --- PID-identity guard (issue #15) --------------------------------------------
# A bare `kill -0 "$pid"` only proves SOME process currently holds that PID — not
# that it's the loop we started. After a reboot (or just enough PID churn) the
# same number can be reassigned to an unrelated process, which would otherwise
# fool bootstrap into believing a stale pidfile's loop is still alive and skip
# relaunching it. Confirm identity via the process's own argv before trusting a
# pidfile: its command line must reference the expected script.
# (Duplicated in stop.sh, which has the same need but for the kill side and
# cannot source this file — lib.sh, the one thing both already share, is out of
# scope for this fix.)
# <pid> <script_path> -> 0 if alive AND running that exact script. `script_path`
# should be the FULL resolved path (issue #80/#81), not just a basename like
# "heartbeat.sh" -- a bare basename would also match another toolkit install's
# same-named script running from a different directory.
pid_is_expected() {
  local pid="$1" script="$2" cmdline=""
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  else
    cmdline="$(ps -o command= -p "$pid" 2>/dev/null)"
  fi
  [[ "$cmdline" == *"$script"* ]]
}

# --- Session ownership record (issue #81) --------------------------------------
# Session names are namespaced per toolkit root by default now (see lib.sh), which
# handles the common case. But SESSION_NAME can still be pinned explicitly (e.g.
# two installs both set SESSION_NAME=orch on purpose, or by accident), so record
# which resolved ORCH_ROOT created the session and compare on reuse. Reusing a
# session this root itself created stays a quiet, harmless reassurance; reusing one
# a DIFFERENT root created must be a loud warning naming both roots -- that silent
# "reusing" line is what hid a second instance for three days.
owner_file="$STATE_DIR/session-owner"

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
  # The master runs unattended, so it skips permission prompts. Workers do NOT
  # (see PR #7): only this orchestrator window is trusted to self-approve.
  # models.orchestrator (issue #25): optional model pin for the master session.
  master_model="$(jq -r '.models.orchestrator // empty' "$here/config.json" 2>/dev/null)"
  tmux send-keys -t "$S:$ORCH_WINDOW" "claude --dangerously-skip-permissions${master_model:+ --model $master_model}" Enter
  if wait_ready "$S:$ORCH_WINDOW" 90; then
    send_prompt "$S:$ORCH_WINDOW" "You are the ORCHESTRATOR for this project. First read the file $here/CLAUDE.md and follow it exactly. Your control CLI is $ORCH_ROOT/orch (e.g. '$ORCH_ROOT/orch spawn w1 sonnet \"task\"', '$ORCH_ROOT/orch status', '$ORCH_ROOT/orch send w1 \"msg\"'). Worker completion and blocked events arrive automatically, prefixed [orchestrator heartbeat]. Acknowledge briefly, then wait for my tasks."
  else
    log "master not ready in 90s; open the window and read $here/CLAUDE.md manually"
  fi
  log "session $S created"
  printf '%s\n' "$ORCH_ROOT" > "$owner_file"
else
  owner="$(cat "$owner_file" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" != "$ORCH_ROOT" ]; then
    say "WARNING: session '$S' already exists but was created by a DIFFERENT toolkit root:" >&2
    say "  this install:  $ORCH_ROOT" >&2
    say "  session owner: $owner" >&2
    say "Two installs are sharing one session name -- set SESSION_NAME to give each its own." >&2
    log "session $S owner mismatch: this=$ORCH_ROOT owner=$owner"
  else
    say "session '$S' already exists; reusing"
    [ -n "$owner" ] || printf '%s\n' "$ORCH_ROOT" > "$owner_file"
  fi
  # Restart/reattach case (issue #41): the master's transcript may be gone (crash,
  # a fresh bootstrap after a compact-and-exit) even though the tmux session and
  # its state files survived. Best-effort nudge it with a rehydrate summary so it
  # doesn't have to reconstruct "what's in flight" from nothing. Skip quietly if
  # rehydrate.sh is missing (older checkout) or the pane isn't ready within a few
  # seconds (e.g. mid-turn) — this must never block or fail bootstrap.
  if [ -x "$here/rehydrate.sh" ] && wait_ready "$S:$ORCH_WINDOW" 5; then
    send_prompt "$S:$ORCH_WINDOW" "$("$here/rehydrate.sh")"
    log "sent rehydrate summary to reused session"
  fi
fi

# Background heartbeat
if [ ! -f "$STATE_DIR/heartbeat.pid" ] || ! pid_is_expected "$(cat "$STATE_DIR/heartbeat.pid" 2>/dev/null)" "$here/heartbeat.sh"; then
  nohup "$here/heartbeat.sh" >>"$STATE_DIR/heartbeat.log" 2>&1 &
  echo $! > "$STATE_DIR/heartbeat.pid"
  log "heartbeat pid $(cat "$STATE_DIR/heartbeat.pid")"
fi

# Background watchdog (if enabled)
if jq -e '.watchdog.enabled // true' "$here/config.json" >/dev/null 2>&1; then
  if [ ! -f "$STATE_DIR/watchdog.pid" ] || ! pid_is_expected "$(cat "$STATE_DIR/watchdog.pid" 2>/dev/null)" "$here/watchdog.sh"; then
    nohup "$here/watchdog.sh" >>"$STATE_DIR/watchdog.log" 2>&1 &
    echo $! > "$STATE_DIR/watchdog.pid"
    log "watchdog pid $(cat "$STATE_DIR/watchdog.pid")"
  fi
fi

say "orchestrator up. attach with:  tmux attach -t $S"
