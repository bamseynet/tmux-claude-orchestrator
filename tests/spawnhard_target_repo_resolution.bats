#!/usr/bin/env bats
# Issue #47: _orch/spawn.sh must resolve the target repo itself when invoked
# directly (not via `./orch`), honoring the same precedence `./orch` implements
# in its own prologue: $PROJECT_ROOT > $ORCH_TARGET_REPO > .target_repo in
# config.json > cwd. Before this fix, spawn.sh only ever read
# ${PROJECT_ROOT:-$(pwd)}, so a direct invocation silently fell through to cwd
# and skipped the config-file/env-var levels entirely.
#
# tmux/git/claude are stubbed; no real tmux window, git worktree, or claude
# process is ever touched. `cd` is real, so canonicalization behavior is
# exercised for real.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"

worker_branch_for() { # <id>
  ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; worker_branch "'"$1"'"'
}

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
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
  PATH="$STUBBIN:$PATH"   # real git stays on PATH

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export SESSION_NAME="orch"
  mkdir -p "$ORCH_ROOT/_orch"

  export TARGET="$BATS_TEST_TMPDIR/target"
  git init -q "$TARGET"
  git -C "$TARGET" config user.email test@example.com
  git -C "$TARGET" config user.name test
  echo hello > "$TARGET/f.txt"
  git -C "$TARGET" add f.txt
  git -C "$TARGET" commit -q -m init

  export OTHERCWD="$BATS_TEST_TMPDIR/othercwd"
  mkdir -p "$OTHERCWD"   # deliberately NOT a git repo, unrelated to TARGET
}

write_config() { # <target_repo value>
  jq -n --arg t "$1" '{target_repo:$t, thresholds:{max_workers:4,min_free_mb:0,est_worker_mb:0}, budget:{enabled:false,max_usd:5.0,est_usd_per_worker:0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
}

@test "spawn.sh invoked directly (no PROJECT_ROOT) honors ORCH_TARGET_REPO over cwd" {
  write_config ""
  cd "$OTHERCWD"
  run env -u PROJECT_ROOT ORCH_TARGET_REPO="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 \
    "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1"* ]]
  run jq -r .task "$ORCH_ROOT/_orch/state/workers/w1.json"
  [[ "$output" == *"do the thing"* ]]
  run git -C "$OTHERCWD" rev-parse --show-toplevel
  [ "$status" -ne 0 ]
}

@test "spawn.sh invoked directly (no PROJECT_ROOT/ORCH_TARGET_REPO) honors .target_repo from config.json over cwd" {
  write_config "$TARGET"
  cd "$OTHERCWD"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 \
    "$SPAWN" w2 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w2"* ]]

  # the worktree must be registered against the CONFIGURED target repo, not cwd.
  run git -C "$TARGET" worktree list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(worker_branch_for w2)"* ]]

  run git -C "$OTHERCWD" rev-parse --show-toplevel
  [ "$status" -ne 0 ]
}

@test "spawn.sh invoked directly still refuses via the relatedness guard when config target_repo is unrelated to the toolkit" {
  # ensure_related_repo() treats a non-git ORCH_ROOT as having nothing to
  # contradict (always related), so make the toolkit dir a real, unrelated git
  # repo here to actually exercise the guard.
  git init -q "$ORCH_ROOT"
  git -C "$ORCH_ROOT" config user.email test@example.com
  git -C "$ORCH_ROOT" config user.name test
  echo toolkit > "$ORCH_ROOT/t.txt"
  git -C "$ORCH_ROOT" add t.txt
  git -C "$ORCH_ROOT" commit -q -m init

  write_config "$TARGET"
  cd "$OTHERCWD"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$SPAWN" w3 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"look unrelated"* ]]
}

@test "spawn.sh invoked directly with none of PROJECT_ROOT/ORCH_TARGET_REPO/.target_repo set falls back to cwd (legacy behavior)" {
  write_config ""
  cd "$TARGET"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$SPAWN" w4 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w4"* ]]
}

@test "spawn.sh still prefers PROJECT_ROOT over ORCH_TARGET_REPO and config.json when all three are set" {
  write_config "$OTHERCWD"
  other_target="$BATS_TEST_TMPDIR/other_target"
  git init -q "$other_target"
  git -C "$other_target" config user.email test@example.com
  git -C "$other_target" config user.name test
  echo x > "$other_target/x.txt"
  git -C "$other_target" add x.txt
  git -C "$other_target" commit -q -m init

  cd "$BATS_TEST_TMPDIR"
  run env PROJECT_ROOT="$TARGET" ORCH_TARGET_REPO="$other_target" \
    "$SPAWN" w5 sonnet "do the thing"
  [ "$status" -eq 0 ]

  run git -C "$TARGET" worktree list
  [[ "$output" == *"$(worker_branch_for w5)"* ]]
  run git -C "$other_target" worktree list
  [[ "$output" != *"$(worker_branch_for w5)"* ]]
}
