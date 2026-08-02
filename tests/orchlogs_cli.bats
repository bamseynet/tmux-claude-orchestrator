#!/usr/bin/env bats
# Hermetic tests for issue #19: `orch logs [heartbeat|watchdog|orch|events]` and
# `orch events`. No tmux window and no `claude` process is ever launched — these
# only read/format files under $ORCH_ROOT/_orch/state.

ORCH="$BATS_TEST_DIRNAME/../orch"

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch/state"
  # `orch` resolves its own root from BASH_SOURCE, not an env var, so run a
  # copy of the entrypoint placed at $ORCH_ROOT — keeps this hermetic (no
  # writes under the real repo's _orch/state).
  cp "$ORCH" "$ORCH_ROOT/orch"
  chmod +x "$ORCH_ROOT/orch"
  ORCH="$ORCH_ROOT/orch"
}

@test "orch logs orch prints the orch.log file" {
  printf '2026-01-01T00:00:00Z hello from orch.log\n' > "$ORCH_ROOT/_orch/state/orch.log"
  run "$ORCH" --repo "$PROJECT_ROOT" logs orch
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from orch.log"* ]]
}

@test "orch logs heartbeat prints the heartbeat.log file" {
  printf 'heartbeat tick\n' > "$ORCH_ROOT/_orch/state/heartbeat.log"
  run "$ORCH" --repo "$PROJECT_ROOT" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"heartbeat tick"* ]]
}

@test "orch logs watchdog prints the watchdog.log file" {
  printf 'watchdog sweep\n' > "$ORCH_ROOT/_orch/state/watchdog.log"
  run "$ORCH" --repo "$PROJECT_ROOT" logs watchdog
  [ "$status" -eq 0 ]
  [[ "$output" == *"watchdog sweep"* ]]
}

@test "orch logs events prints the raw events.jsonl file" {
  printf '{"id":"w1","event":"done","ts":"2026-01-01T00:00:00Z"}\n' > "$ORCH_ROOT/_orch/state/events.jsonl"
  run "$ORCH" --repo "$PROJECT_ROOT" logs events
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"done"'* ]]
}

@test "orch logs reports a friendly message when the log doesn't exist yet" {
  run "$ORCH" --repo "$PROJECT_ROOT" logs watchdog
  [ "$status" -eq 0 ]
  [[ "$output" == *"no watchdog log"* ]]
}

@test "orch logs rejects an unknown log name" {
  run "$ORCH" --repo "$PROJECT_ROOT" logs bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"heartbeat|watchdog|orch|events"* ]]
}

@test "orch events shows a formatted table of the durable event history" {
  {
    printf '{"id":"w1","event":"done","ts":"2026-01-01T00:00:00Z"}\n'
    printf '{"id":"w2","event":"needs-input","ts":"2026-01-01T00:01:00Z"}\n'
  } > "$ORCH_ROOT/_orch/state/events.jsonl"

  run "$ORCH" --repo "$PROJECT_ROOT" events
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"* ]]
  [[ "$output" == *"EVENT"* ]]
  [[ "$output" == *"w1"* ]]
  [[ "$output" == *"done"* ]]
  [[ "$output" == *"w2"* ]]
  [[ "$output" == *"needs-input"* ]]
}

@test "orch events reports a friendly message when there is no history yet" {
  run "$ORCH" --repo "$PROJECT_ROOT" events
  [ "$status" -eq 0 ]
  [[ "$output" == *"no events recorded"* ]]
}

@test "orch help mentions logs and events subcommands" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"orch logs"* ]]
  [[ "$output" == *"orch events"* ]]
}
