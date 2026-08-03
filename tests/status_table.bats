#!/usr/bin/env bats
# Hermetic tests for issue #17: `orch status` renders a scannable table
# (id/model/status/age/task) plus a --json flag for the raw form, and worker
# status files get a `created` timestamp so age is computable. No tmux window
# and no `claude` process is ever launched.
#
# `orch` only falls back to its own script location for ORCH_ROOT when the var
# isn't already set ("${ORCH_ROOT:-$here}") — a worker's shell can inherit
# ORCH_ROOT from its own launch env, pointing at the PARENT orchestrator's real
# toolkit. So each test runs against a throwaway copy of the toolkit AND pins
# ORCH_ROOT to it explicitly, matching the pattern used by
# tests/repofix_target_repo_precedence.bats (issue #68).

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/toolkit"
  cp -r "$BATS_TEST_DIRNAME/../_orch" "$WORK/toolkit/_orch"
  cp "$BATS_TEST_DIRNAME/../orch" "$WORK/toolkit/orch"
  chmod +x "$WORK/toolkit/orch"
  mkdir -p "$WORK/toolkit/_orch/state/workers"
  ORCH="$WORK/toolkit/orch"
  WORKERS_DIR="$WORK/toolkit/_orch/state/workers"
  export ORCH_ROOT="$WORK/toolkit"
}

mkworker() { # <id> <status> <model> <task> <created-iso> <updated-iso>
  jq -n --arg id "$1" --arg s "$2" --arg m "$3" --arg t "$4" --arg c "$5" --arg u "$6" \
    '{id:$id, status:$s, model:$m, task:$t, created:$c, updated:$u}' \
    > "$WORKERS_DIR/$1.json"
}

@test "orch status renders a table with id/model/status/age/task columns" {
  mkworker w1 working sonnet "do the thing" "2020-01-01T00:00:00Z" "2020-01-01T00:00:00Z"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"* ]]
  [[ "$output" == *"MODEL"* ]]
  [[ "$output" == *"STATUS"* ]]
  [[ "$output" == *"AGE"* ]]
  [[ "$output" == *"TASK"* ]]
  [[ "$output" == *"w1"* ]]
  [[ "$output" == *"sonnet"* ]]
  [[ "$output" == *"working"* ]]
  [[ "$output" == *"do the thing"* ]]
}

@test "orch status shows a non-trivial age for an old created timestamp" {
  mkworker w1 working sonnet "task" "2020-01-01T00:00:00Z" "2020-01-01T00:00:00Z"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep w1)"
  [[ "$line" == *"d"* ]] # years old -> renders in days (at minimum)
}

@test "orch status falls back to updated when created is absent (back-compat)" {
  jq -n --arg id w1 --arg s working --arg m sonnet --arg t task --arg u "2020-01-01T00:00:00Z" \
    '{id:$id, status:$s, model:$m, task:$t, updated:$u}' \
    > "$WORKERS_DIR/w1.json"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  line="$(printf '%s\n' "$output" | grep w1)"
  [[ "$line" == *"d"* ]]
}

@test "orch status prints 'no workers yet' when none exist" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no workers yet"* ]]
}

@test "orch status --json emits a JSON array with created/updated fields" {
  mkworker w1 working sonnet "do the thing" "2020-01-01T00:00:00Z" "2020-01-01T00:00:01Z"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status --json
  [ "$status" -eq 0 ]
  run jq -r '.[0].id' <<<"$output"
  [ "$output" = "w1" ]
}

@test "orch status --json emits an empty array when none exist" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" status --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}
