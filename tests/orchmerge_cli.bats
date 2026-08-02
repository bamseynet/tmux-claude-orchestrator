#!/usr/bin/env bats
# Hermetic tests for the `orch merge` dispatch wiring (issue #36): only exercises
# help/usage and dispatch-to-script behavior, so it stays offline and does not
# duplicate the deeper behavioral coverage in orchmerge_merge.bats.

ORCH="$BATS_TEST_DIRNAME/../orch"

@test "orch help lists the merge command" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"./orch merge <id>"* ]]
  [[ "$output" == *"--auto"* ]]
}

@test "orch help still lists every pre-existing subcommand (no regressions)" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  for line in "./orch up" "./orch spawn" "./orch send" "./orch tail" "./orch ask" \
              "./orch clean" "./orch kill" "./orch prune" "./orch status" \
              "./orch collect" "./orch attach" "./orch down" "./orch hud" \
              "./orch logs" "./orch events"; do
    [[ "$output" == *"$line"* ]]
  done
}

@test "orch merge with no id fails with a usage message" {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  printf '{}' > "$ORCH_ROOT/_orch/config.json"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"

  run "$BATS_TEST_DIRNAME/../_orch/merge.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
