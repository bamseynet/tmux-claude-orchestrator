#!/usr/bin/env bats
# Hermetic tests for issue #25: spawn.sh must fall back to models.default_worker
# when no model is given (an empty-string model arg), and support a --preset
# review|test|docs shortcut that bundles a canned model + task + --allow.
#
# tmux/git/claude are stubbed exactly as in spawn.bats; no real window, worktree,
# or claude process is ever launched.

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
}

write_config() { # <default_worker-or-empty>
  if [ -n "${1:-}" ]; then
    jq -n --arg m "$1" '{
      thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0 },
      budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 },
      models: { default_worker: $m }
    }' > "$ORCH_ROOT/_orch/config.json"
  else
    jq -n '{
      thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0 },
      budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 }
    }' > "$ORCH_ROOT/_orch/config.json"
  fi
}

@test "spawn.sh falls back to models.default_worker when model arg is empty" {
  write_config "haiku"
  run "$SPAWN" w1 "" "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1 (haiku)"* ]]
  run jq -r .model "$ORCH_ROOT/_orch/state/workers/w1.json"
  [ "$output" = "haiku" ]
}

@test "spawn.sh errors when model is empty and models.default_worker is unset" {
  write_config ""
  run "$SPAWN" w2 "" "do the thing" --no-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *"model required"* ]]
  [ ! -f "$ORCH_ROOT/_orch/state/workers/w2.json" ]
}

@test "spawn.sh still requires an explicit model when a real model is given" {
  write_config ""
  run "$SPAWN" w3 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w3 (sonnet)"* ]]
}

@test "spawn.sh --preset review bundles model, task and --allow" {
  write_config ""
  run "$SPAWN" w4 --preset review --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w4 (sonnet)"* ]]

  run jq -r .task "$ORCH_ROOT/_orch/state/workers/w4.json"
  [[ "$output" == *"Review the current branch/diff"* ]]

  run jq -c '.permissions.allow' "$PROJECT_ROOT/.claude/settings.local.json"
  [[ "$output" == *"Bash(git diff:*)"* ]]
  [[ "$output" == *"Bash(git log:*)"* ]]
}

@test "spawn.sh --preset docs uses haiku" {
  write_config ""
  run "$SPAWN" w5 --preset docs --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w5 (haiku)"* ]]
}

@test "spawn.sh --preset merges an explicit --allow with the preset's own list" {
  write_config ""
  run "$SPAWN" w6 --preset test --no-worktree --allow "Bash(ls:*)"
  [ "$status" -eq 0 ]
  run jq -c '.permissions.allow' "$PROJECT_ROOT/.claude/settings.local.json"
  [[ "$output" == *"Bash(ls:*)"* ]]
  [[ "$output" == *"Bash(npm test:*)"* ]]
}

@test "spawn.sh rejects an unknown --preset name" {
  write_config ""
  run "$SPAWN" w7 --preset bogus --no-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown preset"* ]]
}
