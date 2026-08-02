#!/usr/bin/env bats
# Hermetic tests for issue #55: the watchdog sweep must never touch the
# master/orchestrator window ($ORCH_WINDOW). Previously every tmux window,
# including the master's own heavy Claude session, was fed through the same
# rate-limit + liveness sweep, so a rate-limited master pane got a
# send_prompt retry-nudge injected into the operator's own session — a bug
# and a prompt-injection vector.
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we
# can source it to reach sweep_window() directly WITHOUT starting the loop or
# a tmux session, same pattern as watchdog_dead.bats / watchdog_rl_cooldown.bats.

bats_require_minimum_version 1.5.0

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  export ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  # Stub out pane_tail so sweep_window (when it doesn't short-circuit) sees a
  # rate-limited pane without needing a real tmux session.
  # shellcheck disable=SC2317  # invoked indirectly via sweep_window, not called directly here
  pane_tail() { printf '%s' "429 too many requests"; }
}

rl_file() { echo "$STATE_DIR/.rl-$1"; }

@test "sweep_window skips the master window entirely: no rl state, no log entry" {
  sweep_window "$ORCH_WINDOW" 65
  [ ! -e "$(rl_file "$ORCH_WINDOW")" ]
  [ ! -e "$LOG" ] || { run ! grep -q "$ORCH_WINDOW" "$LOG"; }
}

@test "sweep_window still sweeps a regular worker window" {
  sweep_window "w1" 65
  [ -e "$(rl_file w1)" ]
  grep -q "rate limit detected on 'w1'" "$LOG"
}

@test "master window is skipped even when named differently via ORCH_WINDOW" {
  export ORCH_WINDOW="mycustommaster"
  sweep_window "mycustommaster" 65
  [ ! -e "$(rl_file mycustommaster)" ]
  [ ! -e "$LOG" ] || { run ! grep -q "mycustommaster" "$LOG"; }
}

@test "main-loop window list skips ORCH_WINDOW alongside real workers" {
  # Simulate one tick's worth of the actual main-loop window iteration (the
  # exact `while IFS= read -r w; do ... sweep_window ...; done` body run
  # against a fixed window list) to prove the wiring, not just the helper.
  windows=$'w1\norchestrator\nw2'
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    sweep_window "$w" 65
  done < <(printf '%s\n' "$windows")

  [ -e "$(rl_file w1)" ]
  [ -e "$(rl_file w2)" ]
  [ ! -e "$(rl_file orchestrator)" ]
  run ! grep -q "'orchestrator'" "$LOG"
}
