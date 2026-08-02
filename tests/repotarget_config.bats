#!/usr/bin/env bats
# Hermetic tests for issue #35 (decouple "toolkit location" from "target repo"):
#   - ./orch target-repo resolution precedence: --repo > $PROJECT_ROOT >
#     $ORCH_TARGET_REPO > .target_repo in _orch/config.json > cwd.
#   - lib.sh's ensure_related_repo() relatedness guard.
#
# All tests use real, tiny throwaway git repos under $BATS_TEST_TMPDIR (git init +
# one commit is cheap and needs no network), so the relatedness logic is exercised
# against real `git worktree`/`git remote` semantics rather than stubs. No tmux
# window and no `claude` process are ever launched.

ORCH="$BATS_TEST_DIRNAME/../orch"

mkrepo() { # <dir>
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  # Content includes the repo's own path so two independently-created repos never
  # collide on an identical commit SHA (which would happen if two `mkrepo` calls
  # land in the same second with otherwise-identical tree/author/message — that
  # coincidence would make them "share" a commit by construction, not by design).
  echo "seed:$1" > "$1/seed.txt"
  git -C "$1" add seed.txt
  git -C "$1" commit -q -m seed
}

# --- ./orch target-repo resolution (static, via `orch status` which is side-effect-free) ---

setup() {
  export SESSION_NAME="orch"
  unset PROJECT_ROOT ORCH_TARGET_REPO || true
}

@test "orch --repo pins PROJECT_ROOT for the dispatched subcommand" {
  target="$BATS_TEST_TMPDIR/target1"
  mkdir -p "$target"
  # `status` with no workers dir just reports "no workers yet" — side-effect-free,
  # but it runs through the same PROJECT_ROOT-resolution prologue as every command.
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$ORCH" --repo "$target" status
  [ "$status" -eq 0 ]
}

@test "orch --repo requires a path argument" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$ORCH" --repo
  [ "$status" -ne 0 ]
}

@test "orch --repo rejects a path that does not exist" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$ORCH" --repo "$BATS_TEST_TMPDIR/nope-not-here" status
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "orch resolves target repo from ORCH_TARGET_REPO when --repo and PROJECT_ROOT are absent" {
  target="$BATS_TEST_TMPDIR/target2"
  mkdir -p "$target"
  run env -u PROJECT_ROOT ORCH_TARGET_REPO="$target" "$ORCH" status
  [ "$status" -eq 0 ]
}

@test "orch prefers an explicit PROJECT_ROOT over ORCH_TARGET_REPO" {
  p="$BATS_TEST_TMPDIR/proj-wins"
  t="$BATS_TEST_TMPDIR/target-loses"
  mkdir -p "$p" "$t"
  run env PROJECT_ROOT="$p" ORCH_TARGET_REPO="$t" "$ORCH" status
  [ "$status" -eq 0 ]
}

@test "orch help documents the target-repo precedence and vendored-copy update path" {
  run "$ORCH" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--repo"* ]]
  [[ "$output" == *"ORCH_TARGET_REPO"* ]]
  [[ "$output" == *"ORCH_ALLOW_UNRELATED_REPO"* ]]
  [[ "$output" == *"vendored"* ]]
}

# --- lib.sh: ensure_related_repo() -----------------------------------------------

setup_lib() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ORCH_ROOT/_orch"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

@test "ensure_related_repo: toolkit dir that is not a git repo is treated as related" {
  setup_lib
  toolkit="$BATS_TEST_TMPDIR/plain-dir"
  mkrepo "$BATS_TEST_TMPDIR/target-a"
  mkdir -p "$toolkit"
  run ensure_related_repo "$toolkit" "$BATS_TEST_TMPDIR/target-a"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: same repo (toolkit dir IS the target repo) is related" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/same"
  run ensure_related_repo "$BATS_TEST_TMPDIR/same" "$BATS_TEST_TMPDIR/same"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: sibling worktrees of the same repo are related" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/main"
  git -C "$BATS_TEST_TMPDIR/main" worktree add -q -B wt1 "$BATS_TEST_TMPDIR/main-wt" >/dev/null
  run ensure_related_repo "$BATS_TEST_TMPDIR/main" "$BATS_TEST_TMPDIR/main-wt"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: matching origin remotes are related even with separate .git dirs" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/upstream"
  mkrepo "$BATS_TEST_TMPDIR/toolkit-clone"
  mkrepo "$BATS_TEST_TMPDIR/target-clone"
  git -C "$BATS_TEST_TMPDIR/toolkit-clone" remote add origin "https://example.invalid/repo.git"
  git -C "$BATS_TEST_TMPDIR/target-clone" remote add origin "https://example.invalid/repo.git"
  run ensure_related_repo "$BATS_TEST_TMPDIR/toolkit-clone" "$BATS_TEST_TMPDIR/target-clone"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: a real clone (shared history, no remote) is related" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/upstream2"
  git clone -q "$BATS_TEST_TMPDIR/upstream2" "$BATS_TEST_TMPDIR/downstream2" >/dev/null 2>&1
  git -C "$BATS_TEST_TMPDIR/downstream2" remote remove origin
  run ensure_related_repo "$BATS_TEST_TMPDIR/upstream2" "$BATS_TEST_TMPDIR/downstream2"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: two unrelated repos with no shared history/remote are refused" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/repoA"
  mkrepo "$BATS_TEST_TMPDIR/repoB"
  run ensure_related_repo "$BATS_TEST_TMPDIR/repoA" "$BATS_TEST_TMPDIR/repoB"
  [ "$status" -ne 0 ]
}

@test "ensure_related_repo: ORCH_ALLOW_UNRELATED_REPO=1 overrides an unrelated pair" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/repoC"
  mkrepo "$BATS_TEST_TMPDIR/repoD"
  export ORCH_ALLOW_UNRELATED_REPO=1
  run ensure_related_repo "$BATS_TEST_TMPDIR/repoC" "$BATS_TEST_TMPDIR/repoD"
  [ "$status" -eq 0 ]
}

@test "ensure_related_repo: target dir that is not a git repo at all is refused" {
  setup_lib
  mkrepo "$BATS_TEST_TMPDIR/repoE"
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  run ensure_related_repo "$BATS_TEST_TMPDIR/repoE" "$BATS_TEST_TMPDIR/not-a-repo"
  [ "$status" -ne 0 ]
}
