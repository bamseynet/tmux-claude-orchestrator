#!/usr/bin/env bats
# Hermetic tests for issue #37 point 3: dead-worker reconciliation must prune the
# worktree (and branch) it leaves behind, not just flip the status file to "dead".
#
# watchdog.sh guards its main loop behind a sourced-vs-executed check, so we can
# source it to reach dead_sweep()/prune_dead_worktree() without starting the long-
# lived loop (same technique as watchdog_dead.bats). PROJECT_ROOT points at a real
# throwaway git repo so the worktree-removal semantics are real, not stubbed.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

mkworker() { # <id> <status>
  printf '{"id":"%s","status":"%s","updated":"x"}\n' "$1" "$2" > "$WORKERS_DIR/$1.json"
}

@test "prune_dead_worktree removes the worktree dir and the orch/<id> branch" {
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w1" "$PROJECT_ROOT/../wt/w1" >/dev/null
  [ -d "$PROJECT_ROOT/../wt/w1" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w1"
  [ "$status" -eq 0 ]

  prune_dead_worktree "$PROJECT_ROOT" w1

  [ ! -d "$PROJECT_ROOT/../wt/w1" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w1"
  [ "$status" -ne 0 ]
}

@test "prune_dead_worktree is idempotent when there is nothing to prune" {
  run prune_dead_worktree "$PROJECT_ROOT" no-such-worker
  [ "$status" -eq 0 ]
}

@test "dead_sweep prunes the confirmed-dead worker's worktree and branch" {
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w2" "$PROJECT_ROOT/../wt/w2" >/dev/null
  mkworker w2 working

  dead_sweep ""   # tick 1: debounce only
  [ -d "$PROJECT_ROOT/../wt/w2" ]

  dead_sweep ""   # tick 2: confirmed dead -> pruned
  run jq -r .status "$WORKERS_DIR/w2.json"
  [ "$output" = "dead" ]
  [ ! -d "$PROJECT_ROOT/../wt/w2" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w2"
  [ "$status" -ne 0 ]
}

@test "dead_sweep leaves the worktree alone for a worker whose window is still alive" {
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w3" "$PROJECT_ROOT/../wt/w3" >/dev/null
  mkworker w3 working

  dead_sweep $'w3\norchestrator'
  dead_sweep $'w3\norchestrator'

  [ -d "$PROJECT_ROOT/../wt/w3" ]
  run jq -r .status "$WORKERS_DIR/w3.json"
  [ "$output" = "working" ]
}
