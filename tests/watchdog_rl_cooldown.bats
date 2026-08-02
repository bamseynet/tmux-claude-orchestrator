#!/usr/bin/env bats
# Hermetic tests for the watchdog non-blocking rate-limit cooldown (issue #13).
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we can
# source it to reach rate_limited() and rl_action() WITHOUT starting the loop or a
# tmux session. No tmux window and no `claude` process are launched — this runs
# fully offline in CI, same pattern as watchdog_dead.bats.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

rl_file() { echo "$STATE_DIR/.rl-$1"; }

@test "rate_limited matches the classic patterns" {
  run rate_limited "boom: rate limit exceeded"
  [ "$status" -eq 0 ]
  run rate_limited "HTTP 429 Too Many Requests"
  [ "$status" -eq 0 ]
  run rate_limited "the API is overloaded right now"
  [ "$status" -eq 0 ]
}

@test "rate_limited matches the broadened 'usage limit' phrasing" {
  run rate_limited "Claude usage limit reached, try again later"
  [ "$status" -eq 0 ]
  run rate_limited "USAGE LIMIT REACHED"
  [ "$status" -eq 0 ]
}

@test "rate_limited does not match ordinary pane output" {
  run rate_limited "Welcome to Claude Code! Try \"help me build\""
  [ "$status" -ne 0 ]
}

@test "rl_action: first sighting starts a cooldown, no earlier state" {
  run rl_action w1 "429 too many requests" 1000 65
  [ "$status" -eq 0 ]
  [ "$output" = "detected" ]
  run cat "$(rl_file w1)"
  [ "$output" = "1065" ]
}

@test "rl_action: still within cooldown window is skipped, file untouched" {
  echo 1065 > "$(rl_file w1)"
  run rl_action w1 "some unrelated pane text" 1030 65
  [ "$status" -eq 0 ]
  [ "$output" = "skip" ]
  run cat "$(rl_file w1)"
  [ "$output" = "1065" ]
}

@test "rl_action: cooldown elapsed but limit still active extends the cooldown" {
  echo 1065 > "$(rl_file w1)"
  run rl_action w1 "still rate limit exceeded" 1070 65
  [ "$status" -eq 0 ]
  [ "$output" = "extended" ]
  run cat "$(rl_file w1)"
  [ "$output" = "1135" ]
}

@test "rl_action: cooldown elapsed and limit cleared triggers a nudge, clears state" {
  echo 1065 > "$(rl_file w1)"
  run rl_action w1 "back to normal, ready for input" 1070 65
  [ "$status" -eq 0 ]
  [ "$output" = "nudge" ]
  [ ! -e "$(rl_file w1)" ]
}

@test "rl_action: no cooldown and pane not rate-limited is a no-op" {
  run rl_action w1 "just working normally" 1000 65
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$(rl_file w1)" ]
}

@test "rl_action tracks each window's cooldown independently" {
  rl_action w1 "429" 1000 65 >/dev/null
  run rl_action w2 "totally fine" 1000 65
  [ "$status" -ne 0 ]
  [ -e "$(rl_file w1)" ]
  [ ! -e "$(rl_file w2)" ]
}
