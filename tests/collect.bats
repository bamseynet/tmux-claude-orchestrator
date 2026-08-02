#!/usr/bin/env bats
# Hermetic tests for _orch/collect.sh (issue #23): the uniform deliverable
# surface that emits a worker's branch diff (git diff <base>...orch/<id>) plus
# its status JSON as one object, so the orchestrator stops scraping panes/diffs
# ad hoc. PROJECT_ROOT points at a real throwaway git repo so the diff semantics
# are real, not stubbed; no tmux window and no `claude` process is ever launched.

COLLECT="$BATS_TEST_DIRNAME/../_orch/collect.sh"

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ORCH_ROOT/_orch"

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q -b main "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
}

mkworker() { # <id> <json>
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  printf '%s' "$2" > "$ORCH_ROOT/_orch/state/workers/$1.json"
}

mkbranch() { # <id> <file-content>
  git -C "$PROJECT_ROOT" branch "orch/$1" main >/dev/null
  git -C "$PROJECT_ROOT" worktree add -q "$PROJECT_ROOT/../wt/$1" "orch/$1" >/dev/null
  echo "$2" >> "$PROJECT_ROOT/../wt/$1/f.txt"
  git -C "$PROJECT_ROOT/../wt/$1" commit -q -am "work on $1"
}

@test "collect.sh emits diff + status for an existing branch and worker" {
  mkworker w1 '{"id":"w1","status":"done","model":"sonnet","task":"do it"}'
  mkbranch w1 "change"

  run "$COLLECT" w1
  [ "$status" -eq 0 ]
  json="$output"

  run jq -r '.id' <<< "$json"; [ "$output" = "w1" ]
  run jq -r '.branch' <<< "$json"; [ "$output" = "orch/w1" ]
  run jq -r '.base' <<< "$json"; [ "$output" = "main" ]
  run jq -r '.branch_exists' <<< "$json"; [ "$output" = "true" ]
  run jq -r '.status.status' <<< "$json"; [ "$output" = "done" ]
  run jq -r '.diff' <<< "$json"; [[ "$output" == *"+change"* ]]
}

@test "collect.sh reports status: null when no status file exists yet" {
  mkbranch w2 "change"

  run "$COLLECT" w2
  [ "$status" -eq 0 ]
  run jq -r '.status' <<< "$output"
  [ "$output" = "null" ]
}

@test "collect.sh reports branch_exists: false and exits nonzero for an unknown id" {
  run bash -c "'$COLLECT' no-such-worker 2>/dev/null"
  [ "$status" -ne 0 ]
  run jq -r '.branch_exists' <<< "$output"
  [ "$output" = "false" ]
}

@test "collect.sh honors --base to diff against a branch other than main" {
  git -C "$PROJECT_ROOT" checkout -q -b develop main
  echo base_change >> "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" commit -q -am "develop change"
  git -C "$PROJECT_ROOT" checkout -q main

  mkbranch w3 "feature_change"

  run "$COLLECT" w3 --base develop
  [ "$status" -eq 0 ]
  json="$output"

  run jq -r '.base' <<< "$json"
  [ "$output" = "develop" ]
  run jq -r '.diff' <<< "$json"
  [[ "$output" == *"+feature_change"* ]]
}

@test "collect.sh fails with a usage message when no id is given" {
  run "$COLLECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "collect.sh output has no 'error' key when the diff succeeds" {
  mkbranch w4 "change"
  run "$COLLECT" w4
  [ "$status" -eq 0 ]
  run jq 'has("error")' <<< "$output"
  [ "$output" = "false" ]
}
