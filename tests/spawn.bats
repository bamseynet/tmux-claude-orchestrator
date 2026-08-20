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

@test "spawn.sh wraps bare commands as Bash(<cmd>:*) rules (issue #78)" {
  run "$SPAWN" w1b sonnet "do the thing" --no-worktree --allow "git, gh , jq"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1b.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(git:*)","Bash(gh:*)","Bash(jq:*)"]' ]
}

@test "spawn.sh passes already-valid tool rules through untouched (issue #78)" {
  run "$SPAWN" w1c sonnet "do the thing" --no-worktree \
    --allow "Bash(git diff:*), WebSearch, WebFetch(domain:example.com), Read"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1c.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(git diff:*)","WebSearch","WebFetch(domain:example.com)","Read"]' ]
}

@test "spawn.sh passes lowercase mcp__ tool names through unwrapped (issue #84)" {
  run "$SPAWN" w1e sonnet "do the thing" --no-worktree \
    --allow "mcp__playwright__browser_click, git"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1e.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["mcp__playwright__browser_click","Bash(git:*)"]' ]
}

@test "spawn.sh passes mcp__ tool names with an args specifier through unwrapped (issue #84)" {
  run "$SPAWN" w1f sonnet "do the thing" --no-worktree \
    --allow 'mcp__playwright__browser_click(selector:*)'
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1f.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["mcp__playwright__browser_click(selector:*)"]' ]
}

@test "spawn.sh passes a capitalised tool name containing underscore/hyphen through unwrapped (issue #84)" {
  # The old `^[A-Z]` heuristic tolerated any character after the first capital,
  # including "_"/"-". Tightening the canonical-name check to [A-Za-z0-9] only
  # would silently start wrapping (and thus disabling) a real tool rule shaped
  # like this — the same failure mode #84 is about, just for a different entry.
  run "$SPAWN" w1h sonnet "do the thing" --no-worktree --allow "Some_Tool, Some-Tool"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1h.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Some_Tool","Some-Tool"]' ]
}

@test "spawn.sh wraps a lowercase non-mcp entry as a shell command (issue #84)" {
  # A lowercase entry that isn't an mcp__ tool and isn't already canonical is
  # still assumed to be a shell command, e.g. a hypothetical bare "foo" — this
  # documents that mcp__ is a special-cased prefix, not a blanket "lowercase
  # means tool name" rule.
  run "$SPAWN" w1g sonnet "do the thing" --no-worktree --allow "foo"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1g.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(foo:*)"]' ]
}

@test "spawn.sh --preset combined with a bare-command --allow yields only valid rules (issue #78)" {
  run "$SPAWN" w1d --preset review --no-worktree --allow "gh,bats"
  [ "$status" -eq 0 ]
  settings="$ORCH_ROOT/_orch/state/settings/w1d.json"
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(gh:*)","Bash(bats:*)","Bash(git diff:*)","Bash(git log:*)","Bash(git show:*)"]' ]
  # no entry should fail the "starts with an uppercase letter" tool-rule requirement
  run jq -e '[.permissions.allow[] | select(test("^[A-Z]") | not)] | length == 0' "$settings"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
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

@test "smoke: spawn.sh end-to-end with --allow \"git,jq\" wraps rules in the worktree settings file (issue #78)" {
  run "$SPAWN" w7b sonnet "do the thing" --allow "git,jq"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w7b (sonnet)"* ]]
  settings="$PROJECT_ROOT/../wt/w7b/.claude/settings.local.json"
  [ -f "$settings" ]
  run jq -c '.permissions.allow' "$settings"
  [ "$output" = '["Bash(git:*)","Bash(jq:*)"]' ]
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
