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
  COLLECT="$BATS_TEST_DIRNAME/../_orch/collect.sh"

  PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" init -q -b main
  git -C "$PROJECT_ROOT" config user.email t@example.com
  git -C "$PROJECT_ROOT" config user.name t
  echo hi > "$PROJECT_ROOT/f.txt"
  # install.sh normally gitignores this in every real target repo (issue #43);
  # without it, spawn.sh's own settings.local.json write into the worktree
  # makes worktree_matches_expected's "is it clean" check see a dirty tree,
  # which only stayed hidden on machines with a coincidental global
  # `.claude/` exclude -- match real usage so respawn-reuse tests are
  # environment-independent.
  echo '.claude/settings.local.json' > "$PROJECT_ROOT/.gitignore"
  git -C "$PROJECT_ROOT" add f.txt .gitignore
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

@test "clean.sh: leaves a leftover pre-#86 (un-namespaced) worktree/branch alone by default (no --sweep-legacy)" {
  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  legacy_wdir="$PROJECT_ROOT/../wt/w9"
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w9" "$legacy_wdir" >/dev/null

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w9
  [ "$status" -eq 0 ]
  # unstamped legacy worktrees carry no ownership info, so this install cannot
  # tell whether it or a different, not-yet-upgraded install owns it -- must
  # NOT be swept without the explicit opt-in (issue #86 review).
  [ -d "$legacy_wdir" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w9"
  [ "$status" -eq 0 ]
}

@test "clean.sh --sweep-legacy: removes a leftover pre-#86 (un-namespaced) worktree and branch for the same id" {
  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  legacy_wdir="$PROJECT_ROOT/../wt/w9"
  git -C "$PROJECT_ROOT" worktree add -q -B "orch/w9" "$legacy_wdir" >/dev/null

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w9 --sweep-legacy
  [ "$status" -eq 0 ]
  [ ! -d "$legacy_wdir" ]
  run git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/orch/w9"
  [ "$status" -ne 0 ]
}

@test "clean.sh: removes the now-empty per-install namespace dir after the worktree is gone" {
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
  namespace_dir="$(dirname "$wdir")"
  [ -d "$namespace_dir" ]

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$CLEAN" w1
  [ "$status" -eq 0 ]
  [ ! -d "$namespace_dir" ]
}

@test "git worktree: two installs' namespaced worktrees sharing a basename get distinct admin dirs (owner-file safety)" {
  # The owner marker lives at <admin-dir>/orch-owner. If two installs' worktrees
  # (../wt/<hashA>/w1 and ../wt/<hashB>/w1 -- same basename "w1", different
  # parent) ever shared one admin dir, the marker would silently point at the
  # wrong install and the foreign-ownership guard would invert (issue #86 review).
  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  wdir_a="$(ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  wdir_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  git -C "$PROJECT_ROOT" worktree add -q -B some-branch-a "$wdir_a" >/dev/null
  git -C "$PROJECT_ROOT" worktree add -q -B some-branch-b "$wdir_b" >/dev/null

  gitdir_a="$(git -C "$wdir_a" rev-parse --git-dir)"
  gitdir_b="$(git -C "$wdir_b" rev-parse --git-dir)"
  [ -n "$gitdir_a" ]
  [ -n "$gitdir_b" ]
  [ "$gitdir_a" != "$gitdir_b" ]

  ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir_a"'"'
  ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir_b"'"'

  owner_a="$(ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owner "'"$wdir_a"'"')"
  owner_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owner "'"$wdir_b"'"')"
  [ "$owner_a" = "$ROOT_A" ]
  [ "$owner_b" = "$ROOT_B" ]
  [ "$owner_a" != "$owner_b" ]
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

@test "clean.sh: a foreign-ownership refusal is all-or-nothing (tmux window untouched too)" {
  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/git "$@"
EOF
  chmod +x "$STUBBIN/git"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$BATS_TEST_TMPDIR/tmux.log"
case "\${1:-}" in
  list-windows) echo w1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  ROOT_A="$BATS_TEST_TMPDIR/root_a"
  ROOT_B="$BATS_TEST_TMPDIR/root_b"
  _setup_install "$ROOT_A"
  _setup_install "$ROOT_B"

  wdir_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "'"$PROJECT_ROOT"'" w1')"
  branch_b="$(ORCH_ROOT="$ROOT_B" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_branch w1')"
  git -C "$PROJECT_ROOT" worktree add -q -B "$branch_b" "$wdir_b" >/dev/null
  ORCH_ROOT="$ROOT_A" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$wdir_b"'"'

  run env ORCH_ROOT="$ROOT_B" PROJECT_ROOT="$PROJECT_ROOT" SESSION_NAME="orch" "$CLEAN" w1
  [ "$status" -eq 1 ]
  # the ownership check must run BEFORE any teardown step, so kill-window must
  # never even be attempted (issue #86 review: refusal must be all-or-nothing).
  ! grep -q 'kill-window' "$BATS_TEST_TMPDIR/tmux.log" 2>/dev/null
}

# --- back-compat read fallback: in-flight pre-#86 workers stay usable ---------------

@test "collect.sh: falls back to the legacy orch/<id> branch when the namespaced one doesn't exist" {
  legacy_branch="orch/w9"
  git -C "$PROJECT_ROOT" branch "$legacy_branch" main >/dev/null
  git -C "$PROJECT_ROOT" worktree add -q "$PROJECT_ROOT/../wt/w9" "$legacy_branch" >/dev/null
  echo change >> "$PROJECT_ROOT/../wt/w9/f.txt"
  git -C "$PROJECT_ROOT/../wt/w9" commit -q -am "pre-upgrade work"

  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  run env ORCH_ROOT="$ROOT" PROJECT_ROOT="$PROJECT_ROOT" "$COLLECT" w9
  [ "$status" -eq 0 ]
  json="$output"
  run jq -r '.branch' <<< "$json"
  [ "$output" = "$legacy_branch" ]
  run jq -r '.branch_exists' <<< "$json"
  [ "$output" = "true" ]
}

@test "watchdog.sh worker_branch_ahead: falls back to the legacy ../wt/<id> worktree when the namespaced one doesn't exist" {
  git -C "$PROJECT_ROOT" worktree add -q -B orch/w9 "$PROJECT_ROOT/../wt/w9" >/dev/null
  echo more > "$PROJECT_ROOT/../wt/w9/g.txt"
  git -C "$PROJECT_ROOT/../wt/w9" add g.txt
  git -C "$PROJECT_ROOT/../wt/w9" commit -q -m "pre-upgrade work"

  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  run env ORCH_ROOT="$ROOT" SESSION_NAME=test bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/watchdog.sh"
    worker_branch_ahead "'"$PROJECT_ROOT"'" w9'
  [ "$output" = "1" ]
}

# --- stray path inside an unrelated enclosing repo is never treated as a worktree ---

@test "lib.sh: a stray non-worktree path under an enclosing git repo is never adopted as an owner-file target" {
  ROOT="$BATS_TEST_TMPDIR/root"
  _setup_install "$ROOT"

  enclosing="$BATS_TEST_TMPDIR/enclosing"
  git init -q "$enclosing"
  git -C "$enclosing" config user.email t@example.com
  git -C "$enclosing" config user.name t
  mkdir -p "$enclosing/wt/hash/w1"   # looks like our layout, but is NOT a real worktree

  run env ORCH_ROOT="$ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; stamp_worktree_owner "'"$enclosing/wt/hash/w1"'"'
  [ "$status" -ne 0 ]
  [ ! -f "$enclosing/.git/orch-owner" ]

  run env ORCH_ROOT="$ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worktree_owner "'"$enclosing/wt/hash/w1"'"'
  [ "$output" = "" ]
}

@test "lib.sh: ORCH_HASH is stable across a trailing slash on ORCH_ROOT" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  h1="$(ORCH_ROOT="$ROOT" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$ORCH_HASH"')"
  h2="$(ORCH_ROOT="$ROOT/" bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$ORCH_HASH"')"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}

@test "lib.sh: ORCH_HASH can be pinned via explicit override (recovery escape hatch)" {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch"
  run env ORCH_ROOT="$ROOT" ORCH_HASH="deadbeef" bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; printf %s "$ORCH_HASH"'
  [ "$output" = "deadbeef" ]
}
