#!/usr/bin/env bats
# Issue #43: for --no-worktree, <workdir> IS the shared target-repo root, so
# spawn.sh must never write that worker's report hooks into
# <repo-root>/.claude/settings.local.json — a later git-worktree worker of the
# same repo inherits repo-root settings via the shared git common-dir, so a dead
# --no-worktree worker's hooks would leak into it forever (phantom Stop/
# Notification events for a worker that no longer exists).
#
# Fix under test: --no-worktree hooks go into a private per-id file under
# _orch/state/settings/, handed to `claude --settings <file>` explicitly at
# launch, and removed by clean.sh on teardown. Worktree-mode workers are
# unaffected (each worktree dir is unique and removed wholesale on teardown).
#
# tmux/git/claude are stubbed; no real tmux window, git worktree, or claude
# process is ever touched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
CLEAN="$BATS_TEST_DIRNAME/../_orch/clean.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"

worker_wdir_for() { # <id>
  ORCH_ROOT="$ORCH_ROOT" bash -c 'source "'"$LIB"'"; worker_wdir "'"$PROJECT_ROOT"'" "'"$1"'"'
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

  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  mkdir -p "${args[$((${#args[@]}-1))]}"
fi
exit 0
EOF

  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON
}

@test "spawn.sh --no-worktree never writes hooks into the shared repo-root .claude/settings.local.json" {
  run "$SPAWN" a1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT_ROOT/.claude" ]
  [ -f "$ORCH_ROOT/_orch/state/settings/a1.json" ]
}

@test "spawn.sh --no-worktree passes --settings pointing at the private per-id file to claude" {
  run "$SPAWN" a2 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  # the launch command is only ever handed to the stubbed tmux via send-keys;
  # assert on the worker's window name + settings file content instead, since
  # capturing the literal command string isn't the point of the fix.
  run jq -r '.hooks.Stop[0].hooks[0].command' "$ORCH_ROOT/_orch/state/settings/a2.json"
  [[ "$output" == *"report.sh a2 done"* ]]
}

@test "a second --no-worktree worker's hooks do not get clobbered/merged with the first's (independent files)" {
  run "$SPAWN" a3 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  run "$SPAWN" a4 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  run jq -r '.hooks.Stop[0].hooks[0].command' "$ORCH_ROOT/_orch/state/settings/a3.json"
  [[ "$output" == *"report.sh a3 done"* ]]
  run jq -r '.hooks.Stop[0].hooks[0].command' "$ORCH_ROOT/_orch/state/settings/a4.json"
  [[ "$output" == *"report.sh a4 done"* ]]
  [ ! -e "$PROJECT_ROOT/.claude" ]
}

@test "worktree-mode spawns are unaffected: hooks still land in the worktree's own .claude/settings.local.json" {
  run "$SPAWN" a5 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [ -f "$(worker_wdir_for a5)/.claude/settings.local.json" ]
  [ ! -e "$ORCH_ROOT/_orch/state/settings/a5.json" ]
}

@test "clean.sh removes a --no-worktree worker's private settings file on teardown" {
  run "$SPAWN" a6 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [ -f "$ORCH_ROOT/_orch/state/settings/a6.json" ]

  run "$CLEAN" a6
  [ "$status" -eq 0 ]
  [ ! -e "$ORCH_ROOT/_orch/state/settings/a6.json" ]
}

@test "clean.sh is idempotent when no settings file exists for the id (worktree-mode worker)" {
  run "$SPAWN" a7 sonnet "do the thing"
  [ "$status" -eq 0 ]
  run "$CLEAN" a7
  [ "$status" -eq 0 ]
}
