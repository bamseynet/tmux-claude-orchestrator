#!/usr/bin/env bats
# Hermetic tests for the terminal-worker reaper (issue #46).
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we can
# source it to reach worker_is_reapable()/reap_terminal_workers() WITHOUT starting
# the loop or a tmux session. clean.sh (invoked by reap_terminal_workers) is the
# REAL script from this repo's _orch/ dir, but it sources lib.sh which honors the
# already-exported ORCH_ROOT/PROJECT_ROOT env vars below, so every path it touches
# stays inside the per-test tmp tree — no real tmux window, no real git repo.

# NOTE: not named ORCH_DIR — lib.sh (sourced by watchdog.sh in setup()) sets a
# global of that exact name to $ORCH_ROOT/_orch, which would clobber it.
REPO_ORCH_DIR="$BATS_TEST_DIRNAME/../_orch"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  # tmux fixture: no session is ever created, so list-windows (from clean.sh,
  # called by reap_terminal_workers) fails exactly as real tmux would against
  # a nonexistent session -- every worker looks reapable from the
  # "still-windowed" guard's point of view unless a test passes its own
  # <live_windows> string directly (reap_terminal_workers takes that as an
  # arg here, not from tmux, so this only affects clean.sh's own kill-window
  # skip-check, which is harmless against an absent session).
  export FAKE_TMUX_STATE="$BATS_TEST_TMPDIR/fake-tmux-state"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-tmux.bash"
  fake_tmux_install_stub "$STUBBIN"

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
  install_fake_git "$STUBBIN" remove-noref
  chmod +x "$STUBBIN/tmux" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch" "$PROJECT_ROOT"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

mkworker() { # <id> <status> <updated-epoch>
  printf '{"id":"%s","status":"%s","updated":"%s"}\n' "$1" "$2" \
    "$(date -u -d "@$3" +%FT%TZ)" > "$WORKERS_DIR/$1.json"
}

# --- worker_is_reapable: pure predicate -----------------------------------------

@test "worker_is_reapable: terminal status past retention is reapable" {
  run worker_is_reapable done 1000 2000 500
  [ "$status" -eq 0 ]
  run worker_is_reapable spawn-failed 1000 2000 500
  [ "$status" -eq 0 ]
}

@test "worker_is_reapable: terminal status within retention is NOT reapable" {
  run worker_is_reapable done 1000 1200 500
  [ "$status" -ne 0 ]
}

@test "worker_is_reapable: non-terminal status is never reapable regardless of age" {
  run worker_is_reapable working 0 999999 0
  [ "$status" -ne 0 ]
  run worker_is_reapable needs-input 0 999999 0
  [ "$status" -ne 0 ]
  run worker_is_reapable spawning 0 999999 0
  [ "$status" -ne 0 ]
}

@test "worker_is_reapable: retention of 0 reaps immediately once terminal" {
  run worker_is_reapable done 1000 1000 0
  [ "$status" -eq 0 ]
}

# --- reap_terminal_workers: behavioural, stubbed tmux + git ---------------------

@test "reap_terminal_workers removes a done worker past retention" {
  wdir="$(worker_wdir "$PROJECT_ROOT" w1)"
  mkdir -p "$wdir"
  mkworker w1 done 1000

  reap_terminal_workers 500 "" 2000
  [ ! -e "$WORKERS_DIR/w1.json" ]
  [ ! -d "$wdir" ]
}

@test "reap_terminal_workers leaves a done worker within retention untouched" {
  mkworker w1 done 1900
  reap_terminal_workers 500 "" 2000
  [ -e "$WORKERS_DIR/w1.json" ]
}

@test "reap_terminal_workers never reaps a non-terminal worker" {
  mkworker w1 working 0
  reap_terminal_workers 0 "" 999999
  [ -e "$WORKERS_DIR/w1.json" ]
}

@test "reap_terminal_workers never reaps a still-windowed worker" {
  mkworker w1 done 0
  reap_terminal_workers 0 $'w1\norchestrator' 999999
  [ -e "$WORKERS_DIR/w1.json" ]
}

@test "reap_terminal_workers reaps spawn-failed workers too" {
  mkworker w1 spawn-failed 0
  reap_terminal_workers 0 "" 999999
  [ ! -e "$WORKERS_DIR/w1.json" ]
}

@test "reap_terminal_workers with retention 0 reaps every terminal worker on demand" {
  mkworker w1 done 999998
  mkworker w2 spawn-failed 999999
  mkworker w3 working 0
  reap_terminal_workers 0 "" 999999
  [ ! -e "$WORKERS_DIR/w1.json" ]
  [ ! -e "$WORKERS_DIR/w2.json" ]
  [ -e "$WORKERS_DIR/w3.json" ]
}

# --- config knob ------------------------------------------------------------------

@test "config.json has a reap_terminal_after_seconds watchdog knob" {
  run jq -r '.watchdog.reap_terminal_after_seconds' "$REPO_ORCH_DIR/config.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ "$output" -gt 0 ]
}

@test "watchdog.sh reads reap_terminal_after_seconds from config" {
  grep -Eq 'reap_terminal_after_seconds' "$REPO_ORCH_DIR/watchdog.sh"
}

@test "watchdog.sh main loop calls reap_terminal_workers each tick" {
  grep -Eq 'reap_terminal_workers' "$REPO_ORCH_DIR/watchdog.sh"
}
