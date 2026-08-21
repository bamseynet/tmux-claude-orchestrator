#!/usr/bin/env bats
# Hermetic tests for issue #22 (task dependencies): `_orch/spawn.sh --after <id>`
# always queues the spawn (never launches immediately, regardless of the resource
# gate) and records `after` in both the queue item and the worker's status file.
#
# tmux/git/claude are stubbed exactly as in tests/spawn.bats; no real tmux window,
# git worktree, or `claude` process is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

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

@test "spawn.sh --after always queues, even with plenty of capacity" {
  run "$SPAWN" w2 sonnet "do the follow-up" --no-worktree --after w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn queued: w2"* ]]
  [[ "$output" == *"w1"* ]]

  # never launched: no tmux window content asserted, but no worktree either
  [ ! -d "$PROJECT_ROOT/../wt/w2" ]

  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w2.json"
  [ "$output" = "queued" ]
  run jq -r .after "$ORCH_ROOT/_orch/state/workers/w2.json"
  [ "$output" = "w1" ]
}

@test "spawn.sh --after records the dependency in the queued item" {
  run "$SPAWN" w2 sonnet "do the follow-up" --no-worktree --after w1
  [ "$status" -eq 0 ]
  run jq -r 'select(.id=="w2") | .after' "$ORCH_ROOT/_orch/state/queue.jsonl"
  [ "$output" = "w1" ]
}

@test "spawn.sh --after requires a dependency <id> argument" {
  run "$SPAWN" w2 sonnet "do the follow-up" --no-worktree --after
  [ "$status" -ne 0 ]
}

@test "spawn.sh without --after still spawns immediately as before" {
  run "$SPAWN" w9 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w9 (sonnet)"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w9.json"
  [ "$output" = "working" ]
}

@test "spawn.sh --after still refuses a duplicate worker id" {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) echo "w6" ;;
esac
exit 0
EOF
  run "$SPAWN" w6 sonnet "do the thing" --no-worktree --after w1
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}
