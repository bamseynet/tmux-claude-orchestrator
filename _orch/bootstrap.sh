#!/usr/bin/env bash
# _orch/bootstrap.sh — start (or reuse) the orchestrator session, launch the master
# Claude with its role, apply the HUD, and start the background loops.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

# session_exists() lives in lib.sh (issue #96) -- every has-session call in the
# toolkit had the same prefix-match hazard this one was originally fixed for
# (issue #92), so it was promoted out of this file to be shared.

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

# Best-effort stop of an already-running heartbeat/watchdog loop and its
# pidfile, used only when --name actually changes the persisted session name
# (below). Both loops resolve SESSION_NAME once, at their own process
# startup, by sourcing lib.sh -- an already-running loop keeps polling the
# OLD name forever and never picks up a rename on its own. Without this, a
# rename leaves the NEW session with no heartbeat/watchdog at all, because
# the pidfile below still names a live (just wrongly-targeted) process and
# `pid_is_expected` has no way to know its target session went stale.
_restart_stale_loop() { # <name> <script_basename>
  local name="$1" script="$2" pidfile pid i=0
  pidfile="$STATE_DIR/$name.pid"
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && pid_is_expected "$pid" "$here/$script"; then
    kill "$pid" 2>/dev/null || true
    while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.25; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    log "session renamed: stopped stale $name (pid $pid) so it relaunches bound to the new name"
  fi
  rm -f "$pidfile"
}

# --- --name flag (issue #92) ---------------------------------------------------
# `orch up --name <name>` sets AND persists this install's session name, so a
# later `orch` invocation in a clean environment (no SESSION_NAME exported)
# still resolves to it — see lib.sh's precedence comment above SESSION_NAME.
# --name outranks even an env-set SESSION_NAME for this invocation.
name_flag=""
bootstrap_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name_flag="${2:?--name needs a value}"; shift 2 ;;
    *) bootstrap_args+=("$1"); shift ;;
  esac
done
set -- ${bootstrap_args[@]+"${bootstrap_args[@]}"}

if [ -n "$name_flag" ]; then
  if ! valid_session_name "$name_flag"; then
    say "orch up: invalid --name '$name_flag' -- session names may contain only letters, digits, '_' and '-' (tmux treats ':' and '.' as target separators, so either would silently target the wrong thing)" >&2
    exit 1
  fi
  # The RESOLVED name this invocation would use WITHOUT --name (lib.sh already
  # computed this above: env > persisted > hash default) -- NOT just the
  # persisted file. Checking only the persisted file misses the two most
  # common cases: the very first --name ever run (no persisted file yet, so
  # the live session is still under the hash default) and a rename away from
  # a session currently pinned via the SESSION_NAME env var. Either miss lets
  # `orch up --name X` silently strand the live master + workers under a name
  # nothing resolves to again — the exact outcome this guard exists to stop.
  resolved_name="$SESSION_NAME"
  # Renaming while the session under the RESOLVED old name is still running is
  # refused, not warned-and-proceeded: silently orphaning a live session under a
  # name nothing will resolve to again is worse than making the operator stop
  # it (or finish up under the old name) first. Re-affirming the SAME name is
  # always allowed (it's a no-op rename).
  if [ "$resolved_name" != "$name_flag" ] && session_exists "$resolved_name"; then
    say "orch up: refusing to rename this install's session from '$resolved_name' to '$name_flag' -- '$resolved_name' is still running." >&2
    say "  Stop it first (./orch down, then tmux kill-session -t $resolved_name) or finish up under the old name, then retry --name $name_flag." >&2
    exit 1
  fi
  SESSION_NAME="$name_flag"
  # A valid --name always wins, even over an invalid $SESSION_NAME env value it
  # is replacing (rv92 finding 3): clear whatever lib.sh recorded about the
  # PRE-override name so the require_valid_session_name check below doesn't
  # block the very flag that fixes the problem.
  SESSION_NAME_ERROR=""
  export SESSION_NAME SESSION_NAME_ERROR
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$SESSION_NAME" > "$STATE_DIR/session-name"
  log "session name persisted: $SESSION_NAME (via --name)"
  if [ "$resolved_name" != "$name_flag" ]; then
    _restart_stale_loop heartbeat heartbeat.sh
    _restart_stale_loop watchdog  watchdog.sh
  fi
fi

require_valid_session_name
S="$SESSION_NAME"
proj="${PROJECT_ROOT:-$(pwd)}"

for dep in tmux jq claude perl git; do
  command -v "$dep" >/dev/null || { say "missing dependency: $dep"; exit 1; }
done

rm -f "$STATE_DIR/.stop"
mkdir -p "$WORKERS_DIR"

# --- Session ownership record (issue #81, hardened by #92) ----------------------
# Session names are namespaced per toolkit root by default now (see lib.sh), which
# handles the common case. But SESSION_NAME can still be pinned explicitly -- via
# SESSION_NAME or, since #92, an operator-chosen --name -- so two installs can
# collide on one name much more easily than by accident. Record which resolved
# ORCH_ROOT created the session and compare on reuse. Reusing a session this root
# itself created stays a quiet, harmless reassurance; reusing one a DIFFERENT
# root created must be a loud warning naming both roots -- that silent "reusing"
# line is what hid a second instance for three days (#81).
#
# The ownership marker lives ON THE TMUX SESSION ITSELF, as a session-scoped
# custom option (@orch_owner) -- NOT in this install's own $STATE_DIR. A file
# under $STATE_DIR can only ever record what THIS install wrote: two different
# ORCH_ROOTs have two entirely separate state directories, so an install that
# adopts a DIFFERENT install's session always finds its own owner-file empty on
# first contact and would print the quiet "reusing" line with no warning ever
# firing -- the guard was unreachable for the one case it exists to catch. A
# tmux option set on the session is visible to and queryable by every install
# that resolves that same session name, closing that gap.
orch_owner_opt() { tmux show-options -t "$1" -v @orch_owner 2>/dev/null || true; } # <session>
orch_owner_set() { tmux set-option  -t "$1" @orch_owner "$2"; }                    # <session> <root>

if ! session_exists "$S"; then
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
  # issue #140: env var (not the disproved prompt-suggestions CLI flag) suppresses
  # the prompt-suggestion ghost row; belt-and-braces alongside pane_has_draft().
  ghost_env="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false "
  tmux send-keys -t "$S:$ORCH_WINDOW" "${ghost_env}claude --dangerously-skip-permissions${master_model:+ --model $master_model}" Enter
  if wait_ready "$S:$ORCH_WINDOW" 90; then
    send_prompt "$S:$ORCH_WINDOW" "You are the ORCHESTRATOR for this project. First read the file $here/CLAUDE.md and follow it exactly. Your control CLI is $ORCH_ROOT/orch (e.g. '$ORCH_ROOT/orch spawn w1 sonnet \"task\"', '$ORCH_ROOT/orch status', '$ORCH_ROOT/orch send w1 \"msg\"'). Worker completion and blocked events arrive automatically, prefixed [orchestrator heartbeat]. Acknowledge briefly, then wait for my tasks."
  else
    log "master not ready in 90s; open the window and read $here/CLAUDE.md manually"
  fi
  log "session $S created"
  orch_owner_set "$S" "$ORCH_ROOT"
else
  owner="$(orch_owner_opt "$S")"
  if [ -n "$owner" ] && [ "$owner" != "$ORCH_ROOT" ]; then
    say "WARNING: session '$S' already exists but was created by a DIFFERENT toolkit root:" >&2
    say "  this install:  $ORCH_ROOT" >&2
    say "  session owner: $owner" >&2
    say "Two installs are sharing one session name -- set --name (or SESSION_NAME) to give each its own." >&2
    log "session $S owner mismatch: this=$ORCH_ROOT owner=$owner"
  else
    say "session '$S' already exists; reusing"
    [ -n "$owner" ] || orch_owner_set "$S" "$ORCH_ROOT"
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
