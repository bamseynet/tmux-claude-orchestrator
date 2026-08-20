#!/usr/bin/env bats
# Hermetic tests for issue #37: _orch/spawn.sh must not silently reuse a
# pre-existing ../wt/<id> dir. On `git worktree add` failure it must refuse and
# emit a spawn-failed event UNLESS the existing path is verifiably a clean
# worktree of the expected repo on branch orch/<id>.
#
# Unlike spawn.bats (which stubs git entirely), these tests use REAL throwaway git
# repos under $BATS_TEST_TMPDIR — the reuse-vs-refuse decision depends on real
# `git worktree list` semantics that a stub can't meaningfully fake. tmux and
# claude are still stubbed, so no real window/session is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"

# Issue #86: the worktree path/branch spawn.sh checks is namespaced per ORCH_ROOT.
worker_wdir_for() { # <id>
  ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; worker_wdir "'"$PROJECT_ROOT"'" "'"$1"'"'
}
worker_branch_for() { # <id>
  ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; worker_branch "'"$1"'"'
}

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
  PATH="$STUBBIN:$PATH"   # real `git` stays on PATH; only tmux/claude are stubbed

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON

  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
}

@test "spawn.sh refuses and reports spawn-failed when ../wt/<id> exists but is not a git worktree at all" {
  mkdir -p "$(worker_wdir_for junk)"
  echo leftover > "$(worker_wdir_for junk)/stale.txt"

  run "$SPAWN" junk sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn-failed"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/junk.json"
  [ "$output" = "spawn-failed" ]
  grep -Fq '"event":"spawn-failed"' "$ORCH_ROOT/_orch/state/inbox.jsonl"
  # the stale dir must be left alone, not silently adopted
  [ -f "$(worker_wdir_for junk)/stale.txt" ]
}

@test "spawn.sh refuses when ../wt/<id> is a worktree of a DIFFERENT repo" {
  other="$BATS_TEST_TMPDIR/other"
  git init -q "$other"
  git -C "$other" config user.email test@example.com
  git -C "$other" config user.name test
  echo x > "$other/x.txt"
  git -C "$other" add x.txt
  git -C "$other" commit -q -m init
  git -C "$other" worktree add -q -B "$(worker_branch_for other1)" "$(worker_wdir_for other1)" >/dev/null

  run "$SPAWN" other1 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn-failed"* ]]
}

@test "spawn.sh reuses a pre-existing ../wt/<id> that IS a clean worktree of the expected repo on orch/<id>" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch_for w1)" "$(worker_wdir_for w1)" >/dev/null

  run "$SPAWN" w1 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1"* ]]
  grep -Fq 'already a clean worktree' "$ORCH_ROOT/_orch/state/orch.log"
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w1.json"
  [ "$output" = "working" ]
}

@test "spawn.sh refuses a pre-existing ../wt/<id> worktree that is on the WRONG branch" {
  git -C "$PROJECT_ROOT" worktree add -q -B "some-other-branch" "$(worker_wdir_for w2)" >/dev/null

  run "$SPAWN" w2 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn-failed"* ]]
}

@test "spawn.sh refuses a pre-existing ../wt/<id> worktree with uncommitted changes" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch_for w3)" "$(worker_wdir_for w3)" >/dev/null
  echo dirty >> "$(worker_wdir_for w3)/f.txt"

  run "$SPAWN" w3 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn-failed"* ]]
}

@test "spawn.sh fails loudly (not silently) when git worktree add fails and no stale path exists" {
  # Check the branch out elsewhere first so `worktree add -B orch/w4 $wdir` fails
  # without ever creating $wdir.
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch_for w4)" "$BATS_TEST_TMPDIR/elsewhere" >/dev/null

  run "$SPAWN" w4 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn-failed"* ]]
  [ ! -d "$(worker_wdir_for w4)" ]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w4.json"
  [ "$output" = "spawn-failed" ]
}

@test "spawn.sh still creates a fresh worktree normally when ../wt/<id> does not exist" {
  run "$SPAWN" w5 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w5"* ]]
  [ -d "$(worker_wdir_for w5)" ]
  run git -C "$(worker_wdir_for w5)" rev-parse --abbrev-ref HEAD
  [ "$output" = "$(worker_branch_for w5)" ]
}
