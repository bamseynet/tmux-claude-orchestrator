#!/usr/bin/env bats
# Hermetic tests for worker_branch_ahead() (issue #50 point 3 building block): how
# many commits is a worker's ../wt/<id> worktree ahead of the upstream default
# branch. Uses a real throwaway git repo (same technique as
# repotarget_watchdog.bats) so the git plumbing is real, not stubbed.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  git -C "$PROJECT_ROOT" checkout -q -B main
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

@test "worker_branch_ahead: no worktree at all prints 0 and fails" {
  run worker_branch_ahead "$PROJECT_ROOT" no-such-worker
  [ "$status" -ne 0 ]
  [ "$output" = "0" ]
}

@test "worker_branch_ahead: worktree with no new commits is 0 (falls back to local main)" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  run worker_branch_ahead "$PROJECT_ROOT" w1
  [ "$output" = "0" ]
}

@test "worker_branch_ahead: counts commits made in the worktree (local main fallback)" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w2)" "$(worker_wdir "$PROJECT_ROOT" w2)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w2)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w2)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w2)" commit -q -m "one"
  echo more2 > "$(worker_wdir "$PROJECT_ROOT" w2)/h.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w2)" add h.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w2)" commit -q -m "two"

  run worker_branch_ahead "$PROJECT_ROOT" w2
  [ "$output" = "2" ]
}

@test "worker_branch_ahead: prefers origin/main over local main when a remote exists" {
  # Bare "origin" pinned at the initial commit; worktree then diverges locally.
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git -C "$PROJECT_ROOT" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$PROJECT_ROOT" push -q origin main
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w3)" "$(worker_wdir "$PROJECT_ROOT" w3)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w3)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w3)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w3)" commit -q -m "one"

  run worker_branch_ahead "$PROJECT_ROOT" w3
  [ "$output" = "1" ]
}
