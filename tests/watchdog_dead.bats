#!/usr/bin/env bats
# Hermetic tests for the watchdog dead-worker reconciliation sweep (issue #9).
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we can
# source it to reach worker_is_orphaned() and dead_sweep() WITHOUT starting the
# loop. ORCH_ROOT points at a temp tree (lib.sh derives every path from it), and we
# drive dead_sweep() with a fake newline list of live tmux window names. No tmux
# window and no `claude` process are launched — this runs fully offline in CI.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

mkworker() { # <id> <status>
  printf '{"id":"%s","status":"%s","updated":"x"}\n' "$1" "$2" > "$WORKERS_DIR/$1.json"
}

@test "worker_is_orphaned: active status with no live window is orphaned" {
  run worker_is_orphaned $'a\nb' working w1
  [ "$status" -eq 0 ]
  run worker_is_orphaned $'a\nb' spawning w1
  [ "$status" -eq 0 ]
}

@test "worker_is_orphaned: active status WITH a live window is not orphaned" {
  run worker_is_orphaned $'w1\norchestrator' working w1
  [ "$status" -ne 0 ]
}

@test "worker_is_orphaned: terminal status is never orphaned" {
  run worker_is_orphaned '' done w1
  [ "$status" -ne 0 ]
  run worker_is_orphaned '' needs-input w1
  [ "$status" -ne 0 ]
  run worker_is_orphaned '' '' w1
  [ "$status" -ne 0 ]
}

@test "dead_sweep flags a dead worker after the debounce, emits exactly one event" {
  mkworker w1 working
  # tick 1: window gone -> debounce marker only, no event yet
  dead_sweep ""
  [ ! -s "$INBOX" ]
  run jq -r .status "$WORKERS_DIR/w1.json"
  [ "$output" = "working" ]
  # tick 2: still gone -> declared dead
  dead_sweep ""
  run cat "$INBOX"
  [[ "$output" == *'"event":"dead"'* ]]
  [[ "$output" == *'"id":"w1"'* ]]
  run jq -r .status "$WORKERS_DIR/w1.json"
  [ "$output" = "dead" ]
  # tick 3+: status is now dead -> no spam
  : > "$INBOX"
  dead_sweep ""
  dead_sweep ""
  [ ! -s "$INBOX" ]
}

@test "dead_sweep leaves a worker whose window is still alive untouched" {
  mkworker w2 working
  dead_sweep $'w2\norchestrator'
  dead_sweep $'w2\norchestrator'
  [ ! -s "$INBOX" ]
  run jq -r .status "$WORKERS_DIR/w2.json"
  [ "$output" = "working" ]
}

@test "dead_sweep ignores workers already in a terminal status" {
  mkworker w3 done
  dead_sweep ""
  dead_sweep ""
  [ ! -s "$INBOX" ]
  run jq -r .status "$WORKERS_DIR/w3.json"
  [ "$output" = "done" ]
}

@test "dead_sweep debounce resets when the window reappears" {
  mkworker w4 working
  dead_sweep ""                 # miss 1
  dead_sweep $'w4'              # window back -> reset
  dead_sweep ""                 # miss 1 again, not yet dead
  [ ! -s "$INBOX" ]
  run jq -r .status "$WORKERS_DIR/w4.json"
  [ "$output" = "working" ]
}
