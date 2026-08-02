#!/usr/bin/env bash
# _orch/stop.sh — stop the background loops. Leaves the tmux session running so you
# can inspect workers. Kill the session yourself when done.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

# --- PID-identity guard (issue #15) --------------------------------------------
# A bare `kill -0`/`kill` on whatever PID happens to be in the pidfile is not
# enough: after a reboot (or enough PID churn) that number can belong to a wholly
# unrelated process, and blindly signalling it would kill a stranger instead of
# our loop. Confirm identity via the process's own argv first.
# (Duplicated from bootstrap.sh, which has the same need but for the launch side
# and cannot source this file either — lib.sh, the one thing both already
# share, is out of scope for this fix.)
pid_is_expected() { # <pid> <script_basename> -> 0 if alive AND running that script
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

touch "$STATE_DIR/.stop"
for p in heartbeat watchdog; do
  pid="$(cat "$STATE_DIR/$p.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && pid_is_expected "$pid" "$p.sh"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$STATE_DIR/$p.pid"
done
log "stopped background loops"
echo "stopped heartbeat + watchdog."
echo "session '$SESSION_NAME' still running — kill it with:  tmux kill-session -t $SESSION_NAME"
