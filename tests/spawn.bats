#!/usr/bin/env bats
# Hermetic tests for _orch/spawn.sh: --allow/--resume/--continue flag parsing, the
# generated per-worker settings.local.json (report hooks + permissions.allow), and
# a mocked tmux/claude smoke run end-to-end (issue #26).
#
# tmux and git are replaced with on-PATH stubs; `claude` is never actually shelled
# out to by spawn.sh (it only ends up as literal text sent through the stubbed
# tmux send-keys), but a stub is provided on PATH too, so nothing could reach a
# real Claude Code session even if that ever changed. No real tmux window, git
# worktree, or `claude` process is ever launched — fully offline in CI.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)  exit 0 ;;                       # no existing window with this id
  capture-pane)  echo '> ready for shortcuts' ;;  # always looks idle/ready
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

@test "spawn.sh writes report hooks and a permissions.allow list parsed from --allow" {
  run "$SPAWN" w1 sonnet "do the thing" --no-worktree --allow "Bash(ls:*), Bash(cat:*)"
  [ "$status" -eq 0 ]

  # issue #43: --no-worktree hooks must NOT land in the shared repo root (they'd
  # leak into every worktree worker of this repo via the shared git common-dir)
  # — they go in a private per-id file instead, handed to `claude --settings`.
  settings="$ORCH_ROOT/_orch/state/settings/w1.json"
  [ -f "$settings" ]
  [ ! -f "$PROJECT_ROOT/.claude/settings.local.json" ]
  run jq -r '.hooks.Stop[0].hooks[0].command' "$settings"
  [[ "$output" == *"report.sh w1 done"* ]]
  run jq -r '.hooks.Notification[0].hooks[0].command' "$settings"
  [[ "$output" == *"report.sh w1 needs-input"* ]]
  run jq -r '.hooks.SubagentStop[0].hooks[0].command' "$settings"
  [[ "$output" == *"report.sh w1 subagent-done"* ]]
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(ls:*)","Bash(cat:*)"]' ]
}

@test "spawn.sh omits permissions.allow entirely when --allow is not given" {
  run "$SPAWN" w2 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  run jq 'has("permissions")' "$ORCH_ROOT/_orch/state/settings/w2.json"
  [ "$output" = "false" ]
}

@test "spawn.sh --resume forces --no-worktree (Claude keys sessions by project dir)" {
  run "$SPAWN" w3 sonnet "do the thing" --resume abc123
  [ "$status" -eq 0 ]
  # forced --no-worktree: settings land in the private per-id file, not a
  # ../wt/w3 worktree, and not the shared project root either (issue #43).
  [ -f "$ORCH_ROOT/_orch/state/settings/w3.json" ]
  [ ! -f "$PROJECT_ROOT/.claude/settings.local.json" ]
  [ ! -d "$PROJECT_ROOT/../wt/w3" ]
  grep -Fq 'resume requested -> forcing --no-worktree' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "spawn.sh --resume requires a session-id argument" {
  run "$SPAWN" w3b sonnet "do the thing" --resume
  [ "$status" -ne 0 ]
}

@test "spawn.sh --continue also forces --no-worktree (it sets the resume flag too)" {
  run "$SPAWN" w4 sonnet "do the thing" --continue
  [ "$status" -eq 0 ]
  [ ! -d "$PROJECT_ROOT/../wt/w4" ]
  grep -Fq 'resume requested -> forcing --no-worktree' "$ORCH_ROOT/_orch/state/orch.log"
}

@test "spawn.sh --no-worktree without --continue/--resume stays in the project dir, no forcing log" {
  run "$SPAWN" w4b sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [ -f "$ORCH_ROOT/_orch/state/settings/w4b.json" ]
  [ ! -f "$PROJECT_ROOT/.claude/settings.local.json" ]
  ! grep -Fq 'resume requested' "$ORCH_ROOT/_orch/state/orch.log" 2>/dev/null
}

@test "spawn.sh rejects an unknown flag" {
  run "$SPAWN" w5 sonnet "do the thing" --bogus-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "spawn.sh refuses a duplicate worker id already present as a tmux window" {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "w6" ;;
esac
exit 0
EOF
  run "$SPAWN" w6 sonnet "do the thing" --no-worktree
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "smoke: spawn.sh end-to-end with mocked tmux/git/claude marks the worker working" {
  run "$SPAWN" w7 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w7 (sonnet)"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w7.json"
  [ "$output" = "working" ]
  [ -d "$PROJECT_ROOT/../wt/w7" ]
  [ -f "$PROJECT_ROOT/../wt/w7/.claude/settings.local.json" ]
}

@test "smoke: spawn.sh queues instead of launching when the concurrency gate is at cap" {
  jq '.thresholds.max_workers = 0' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  run "$SPAWN" w8 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn queued: w8"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w8.json"
  [ "$output" = "queued" ]
  [ ! -d "$PROJECT_ROOT/../wt/w8" ]
}
