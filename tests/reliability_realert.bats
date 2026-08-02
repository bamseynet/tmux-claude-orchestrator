#!/usr/bin/env bats
# Hermetic tests for the bounded/backoff re-alert helper (issue #50 point 4),
# which replaced the old fire-once "alerted" flag. Pure function, no tmux/fs.
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we can
# source it to reach realert_due() WITHOUT starting the loop (same technique as
# watchdog_dead.bats).

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

@test "realert_due: count=0 (never alerted) is always due" {
  run realert_due 0 0 90 1800 100000
  [ "$status" -eq 0 ]
}

@test "realert_due: first re-alert waits exactly base_seconds" {
  # last alert at t=1000, base=90 -> not due until t=1090
  run realert_due 1000 1 90 1800 1089
  [ "$status" -ne 0 ]
  run realert_due 1000 1 90 1800 1090
  [ "$status" -eq 0 ]
}

@test "realert_due: backs off exponentially (base * 2^(count-1))" {
  # count=2 -> wait 180s; count=3 -> wait 360s
  run realert_due 1000 2 90 1800 1179
  [ "$status" -ne 0 ]
  run realert_due 1000 2 90 1800 1180
  [ "$status" -eq 0 ]
  run realert_due 1000 3 90 1800 1359
  [ "$status" -ne 0 ]
  run realert_due 1000 3 90 1800 1360
  [ "$status" -eq 0 ]
}

@test "realert_due: backoff is capped at max_seconds" {
  # count=10 would be base*2^9=46080s, way past cap of 1800
  run realert_due 1000 10 90 1800 2799
  [ "$status" -ne 0 ]
  run realert_due 1000 10 90 1800 2800
  [ "$status" -eq 0 ]
}
