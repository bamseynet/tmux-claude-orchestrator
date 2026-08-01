#!/usr/bin/env bats
# Hermetic tests for the ./orch entrypoint dispatch.
# These exercise only the help/usage path, which spawns no tmux window and
# launches no `claude` process, so they run fully offline in CI.

ORCH="$BATS_TEST_DIRNAME/../orch"

@test "orch help prints the usage banner and exits 0" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux + Claude Code orchestrator"* ]]
  [[ "$output" == *"./orch spawn"* ]]
}

@test "bare orch defaults to help" {
  run "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux + Claude Code orchestrator"* ]]
}

@test "unknown subcommand falls through to help" {
  run "$ORCH" definitely-not-a-real-command
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux + Claude Code orchestrator"* ]]
}
