#!/usr/bin/env bats
# Hermetic tests for issue #86: the git layer (worktree path + branch name) is
# namespaced per toolkit root, same as #81 namespaced the tmux session — so two
# orch installs targeting the SAME repo with the SAME worker id never silently
# share a worktree/branch. Also covers the ownership marker: even if two installs
# somehow land on the same path, the second one refuses loudly instead of the old
# "already a clean worktree ... reusing" silent adoption.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
esac
exit 0
EOF
  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"
  SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  CLEAN="$BATS_TEST_DIRNAME/../_orch/clean.sh"

  PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.email t@example.com
  git -C "$PROJECT_ROOT" config user.name t
  echo hi > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
  export PROJECT_ROOT
}

_setup_install() { # <root_var_name> -> exports ORCH_ROOT/config for a fresh install
  local root="$1"
  mkdir -p "$root/_orch/state"
  cat > "$root/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON
}

# --- namespacing: two different ORCH_ROOTs never collide ---------------------------

@test "lib.sh: worker_wdir/worker_branch differ for two different ORCH_ROOTs" {
  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  wdir_a="$(ORCH_ROOT="$ROOT_A" PROJECT_ROOT="$PROJECT_ROOT" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "$PROJECT_ROOT" w1')"
  wdir_b="$(ORCH_ROOT="$ROOT_B" PROJECT_ROOT="$PROJECT_ROOT" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "$PROJECT_ROOT" w1')"
  branch_a="$(ORCH_ROOT="$ROOT_A" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  branch_b="$(ORCH_ROOT="$ROOT_B" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"

  [ -n "$wdir_a" ]; [ -n "$wdir_b" ]
  [ "$wdir_a" != "$wdir_b" ]
  [ "$branch_a" != "$branch_b" ]
}

@test "spawn.sh: two ORCH_ROOTs targeting the same repo with the same id get distinct worktrees and branches" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "add" ]; then
  exec /usr/bin/git "$@"
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"

  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  run env ORCH_ROOT="$ROOT_A" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task one"
  [ "$status" -eq 0 ]
  run env ORCH_ROOT="$ROOT_B" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task two"
  [ "$status" -eq 0 ]

  wdir_a="$(ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  wdir_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  branch_a="$(ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  branch_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"

  [ "$wdir_a" != "$wdir_b" ]
  [ -d "$wdir_a" ]
  [ -d "$wdir_b" ]
  run git -C "$wdir_a" rev-parse --abbrev-ref HEAD
  [ "$output" = "$branch_a" ]
  run git -C "$wdir_b" rev-parse --abbrev-ref HEAD
  [ "$output" = "$branch_b" ]
}

# --- ownership marker: foreign adoption is refused loudly ---------------------------

@test "lib.sh: worktree_owner/worktree_owned_by_other reflect the stamped owner correctly" {
  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  wdir="$BATS_TEST_TMPDIR/some_wt"
  git -C "$PROJECT_ROOT" worktree add -q -B some-branch "$wdir" >/dev/null

  run env ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir"'"'
  [ "$status" -eq 0 ]

  run env ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owner "'"$wdir"'"'
  [ "$output" = "$ROOT_A" ]

  run env ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owned_by_other "'"$wdir"'"'
  [ "$status" -ne 0 ]   # same install -> NOT foreign

  run env ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owned_by_other "'"$wdir"'"'
  [ "$status" -eq 0 ]   # different install -> foreign
}

@test "spawn.sh: refuses loudly (spawn-failed, not silent reuse) when the target worktree is owned by a different orch install" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"

  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  # Pre-create install B's expected worktree/branch for w1, but stamp it as
  # owned by install A -- the shape a genuine (if astronomically unlikely) hash
  # collision between two different ORCH_ROOTs would leave behind.
  wdir_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  branch_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  git -C "$PROJECT_ROOT" worktree add -q -B "$branch_b" "$wdir_b" >/dev/null
  ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir_b"'"'

  run env ORCH_ROOT="$ROOT_B" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task two"
  [ "$status" -eq 1 ]
  [[ "$output" == *"owned by a different orch install"* ]]
  [[ "$output" == *"$ROOT_A"* ]]
  [[ "$output" != *"reusing"* ]]
  run jq -r .status "$ROOT_B/_orch/state/workers/w1.json"
  [ "$output" = "spawn-failed" ]
  # the foreign worktree itself must be left untouched
  [ -d "$wdir_b" ]
}

# --- respawn-after-clean reuse is preserved for the SAME install --------------------

@test "spawn.sh: same install can still reuse its own clean worktree after a failed inject (respawn)" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"

  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task one"
  [ "$status" -eq 0 ]

  # Respawn the same id from the same install: worktree/branch already exist,
  # clean, owned by us -> must reuse, not fail.
  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task one again"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1"* ]]
}

# --- clean.sh cleans up the namespaced layout ---------------------------------------

@test "clean.sh: removes the namespaced worktree and branch" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"

  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$SPAWN" w1 sonnet "task one"
  [ "$status" -eq 0 ]
  wdir="$(ORCH_ROOT="$ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  branch="$(ORCH_ROOT="$ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  [ -d "$wdir" ]

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w1
  [ "$status" -eq 0 ]
  [ ! -d "$wdir" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch"
  [ "$status" -ne 0 ]
}

@test "clean.sh: sweeps a leftover pre-#86 (un-namespaced) worktree and branch for the same id" {
  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  legacy_wdir="$PROJECT_ROOT/../wt/w9"
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w9" "$legacy_wdir" >/dev/null

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w9
  [ "$status" -eq 0 ]
  [ ! -d "$legacy_wdir" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w9"
  [ "$status" -ne 0 ]
}

@test "clean.sh: refuses to remove a worktree owned by a different orch install" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"

  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  wdir_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  branch_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  git -C "$PROJECT_ROOT" worktree add -q -B "$branch_b" "$wdir_b" >/dev/null
  ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir_b"'"'

  run env ORCH_ROOT="$ROOT_B" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w1
  [ "$status" -eq 1 ]
  [[ "$output" == *"owned by a different orch install"* ]]
  [ -d "$wdir_b" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch_b"
  [ "$status" -eq 0 ]
}
