#!/usr/bin/env bats
# Hermetic regression tests for the spawn-robustness guards.
# These read static files only (config.json + shell sources); they launch no tmux
# window and no `claude` process, so they run fully offline in CI.

ORCH_DIR="$BATS_TEST_DIRNAME/../_orch"

@test "config.json defines watchdog.stall_seconds (default 90)" {
  run jq -r '.watchdog.stall_seconds' "$ORCH_DIR/config.json"
  [ "$status" -eq 0 ]
  [ "$output" = "90" ]
}

@test "spawn.sh prepends the exact anti-skill preamble to the injected task" {
  grep -Fq '[Orchestrated task — complete it directly. Do not invoke any skill unless this task explicitly requires one.] ' "$ORCH_DIR/spawn.sh"
}

@test "spawn.sh notifies the master with a spawn-failed inbox event" {
  grep -Fq '"event":"spawn-failed"' "$ORCH_DIR/spawn.sh"
}

@test "watchdog.sh emits a stalled inbox event" {
  # event name is interpolated (liveness_check also emits "needs-input-stalled"
  # and "ready-for-review" via the same printf, issue #50), so assert on the
  # literal "stalled" event-name assignment instead of the full inbox line.
  grep -Fq 'ev="stalled"' "$ORCH_DIR/watchdog.sh"
}

@test "watchdog.sh reads the stall threshold from config" {
  grep -Fq '.watchdog.stall_seconds // 90' "$ORCH_DIR/watchdog.sh"
}
