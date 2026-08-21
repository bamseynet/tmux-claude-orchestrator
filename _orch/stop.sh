#!/usr/bin/env bash
# _orch/stop.sh — stop the background loops. Leaves the tmux session running so you
# can inspect workers. Kill the session yourself when done.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

# --- PID-identity guard (issue #15, hardened by #80/#81) ------------------------
# A bare `kill -0`/`kill` on whatever PID happens to be in the pidfile is not
# enough: after a reboot (or enough PID churn) that number can belong to a wholly
# unrelated process, and blindly signalling it would kill a stranger instead of
# our loop. Confirm identity via the process's own argv first, matching against
# the FULL resolved script path (not a bare basename like "heartbeat.sh") so a
# different toolkit install's same-named script is never caught by accident.
# (Duplicated from bootstrap.sh, which has the same need but for the launch side
# and cannot source this file either — lib.sh, the one thing both already
# share, is out of scope for this fix.)
pid_is_expected() { # <pid> <script_path> -> 0 if alive AND running that exact script
  local pid="$1" script_path="$2" cmdline=""
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  else
    cmdline="$(ps -o command= -p "$pid" 2>/dev/null)"
  fi
  case "$cmdline" in
    *"$script_path"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Path-based fallback (issue #80): when the pidfile is stale or missing, find any
# LIVE process whose argv references this exact toolkit root's script, rather than
# giving up. Scans /proc directly (Linux; the primary target) and falls back to
# `ps` elsewhere. Matched as a literal substring (case pattern, not a regex), so a
# script path containing shell/regex metacharacters can't misbehave.
find_pids_for_script() { # <script_path> -> newline-separated live pids running it
  local script="$1" pid cmdline
  if [ -d /proc ]; then
    for pid in /proc/[0-9]*; do
      pid="${pid#/proc/}"
      cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
      case "$cmdline" in
        *"$script"*) printf '%s\n' "$pid" ;;
      esac
    done
  else
    ps -eo pid=,command= 2>/dev/null | while read -r pid rest; do
      case "$rest" in
        *"$script"*) printf '%s\n' "$pid" ;;
      esac
    done
  fi
}

# Stop one loop by name (issue #80): resolve candidate PIDs from BOTH the pidfile
# (identity-checked) and a path-based scan (catches a stale/missing pidfile
# without ever touching a stranger process), signal them, then POLL to confirm
# they actually died before reporting success — escalating to SIGKILL if a plain
# TERM doesn't land in time. Never prints/reports "stopped" without verifying.
# Returns 0 only if every candidate is confirmed gone; 1 (naming survivors) if not.
stop_loop() { # <name> <script_basename>
  local name="$1" script="$2"
  local script_path="$here/$script"
  local pidfile="$STATE_DIR/$name.pid"
  local candidates="" pf_pid found pid

  pf_pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pf_pid" ] && pid_is_expected "$pf_pid" "$script_path"; then
    candidates=" $pf_pid"
  fi

  while IFS= read -r found; do
    [ -n "$found" ] || continue
    case " $candidates " in
      *" $found "*) ;;
      *) candidates="$candidates $found" ;;
    esac
  done < <(find_pids_for_script "$script_path")

  rm -f "$pidfile"

  if [ -z "${candidates// /}" ]; then
    log "stop $name: nothing running"
    return 0
  fi

  for pid in $candidates; do
    kill "$pid" 2>/dev/null || true
  done

  local i=0 alive
  while [ "$i" -lt 20 ]; do
    alive=0
    for pid in $candidates; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    if [ "$alive" -eq 0 ]; then
      log "stop $name: confirmed stopped (pids:$candidates)"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done

  # Escalate: a plain TERM didn't land within ~5s.
  for pid in $candidates; do
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done
  sleep 0.25

  local survivors=""
  for pid in $candidates; do
    if kill -0 "$pid" 2>/dev/null; then survivors="$survivors $pid"; fi
  done

  if [ -z "${survivors// /}" ]; then
    log "stop $name: stopped after SIGKILL escalation (pids:$candidates)"
    return 0
  fi

  log "stop $name: FAILED to stop, surviving pids:$survivors"
  say "$name: FAILED to stop — still running, pid(s):$survivors" >&2
  return 1
}

touch "$STATE_DIR/.stop"

failed=""
stop_loop heartbeat heartbeat.sh || failed="$failed heartbeat"
stop_loop watchdog  watchdog.sh  || failed="$failed watchdog"

if [ -z "${failed// /}" ]; then
  log "stopped background loops"
  say "stopped heartbeat + watchdog."
  say "session '$SESSION_NAME' still running — kill it with:  tmux kill-session -t $SESSION_NAME"
  exit 0
fi

say "down FAILED to fully stop:$failed — see the surviving pid(s) above; loops are still running." >&2
exit 1
