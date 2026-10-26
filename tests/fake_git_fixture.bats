#!/usr/bin/env bats
# Pins the shared fake-git fixture's three modes (issue #180): `add` (spawn
# tests), `remove-noref` and `remove-ref` (clean/reap tests). A fixture nobody
# tests is just a bigger version of the copy-paste drift it replaced.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$STUBBIN"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
}

@test "fake-git add: worktree add mkdirs the path, skipping -b <br> and a trailing commit-ish" {
  install_fake_git "$STUBBIN"
  run "$STUBBIN/git" worktree add -b br "$BATS_TEST_TMPDIR/wt1" origin/main
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/wt1" ]
  [ ! -e origin/main ]
}

@test "fake-git add: -C <dir> prefix shifts the offset" {
  install_fake_git "$STUBBIN"
  run "$STUBBIN/git" -C /nonexistent worktree add "$BATS_TEST_TMPDIR/wt2"
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/wt2" ]
}

@test "fake-git add: worktree remove and show-ref are no-ops exiting 0" {
  install_fake_git "$STUBBIN"
  mkdir -p "$BATS_TEST_TMPDIR/keep"
  run "$STUBBIN/git" worktree remove --force "$BATS_TEST_TMPDIR/keep"
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/keep" ]
  run "$STUBBIN/git" show-ref --verify refs/heads/x
  [ "$status" -eq 0 ]
}

@test "fake-git remove-noref: worktree remove deletes the target and not a sibling" {
  install_fake_git "$STUBBIN" remove-noref
  mkdir -p "$BATS_TEST_TMPDIR/gone" "$BATS_TEST_TMPDIR/sibling"
  run "$STUBBIN/git" worktree remove --force "$BATS_TEST_TMPDIR/gone"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/gone" ]
  [ -d "$BATS_TEST_TMPDIR/sibling" ]
}

@test "fake-git remove-noref: worktree add does not create anything; show-ref exits 1" {
  install_fake_git "$STUBBIN" remove-noref
  run "$STUBBIN/git" worktree add "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/nope" ]
  run "$STUBBIN/git" show-ref --verify refs/heads/x
  [ "$status" -eq 1 ]
}

@test "fake-git remove-ref: show-ref exits 0, worktree remove still deletes" {
  install_fake_git "$STUBBIN" remove-ref
  mkdir -p "$BATS_TEST_TMPDIR/gone"
  run "$STUBBIN/git" show-ref --verify refs/heads/x
  [ "$status" -eq 0 ]
  run "$STUBBIN/git" -C /nonexistent worktree remove "$BATS_TEST_TMPDIR/gone"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/gone" ]
}

@test "fake-git: unknown subcommand exits 0 in every mode" {
  for m in add remove-noref remove-ref; do
    install_fake_git "$STUBBIN" "$m"
    run "$STUBBIN/git" frobnicate --whatever
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "fake-git: unknown mode is rejected" {
  run install_fake_git "$STUBBIN" bogus
  [ "$status" -ne 0 ]
}
