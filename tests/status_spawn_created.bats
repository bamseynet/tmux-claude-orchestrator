#!/usr/bin/env bats
# Hermetic tests for issue #17: spawn.sh stamps a `created` timestamp on the
# worker's status file (in addition to `updated`), so age is computable later.
#
# tmux/git/claude are stubbed exactly as in tests/spawn.bats; no real tmux
# window, git worktree, or `claude` process is ever launched.

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

@test "spawn.sh stamps a created timestamp on the worker status file" {
  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  f="$ORCH_ROOT/_orch/state/workers/w1.json"
  [ -f "$f" ]
  run jq -r '.created' "$f"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ -n "$output" ]
  # ISO-8601 UTC, same shape as `updated`
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "spawn.sh's created and updated timestamps agree at spawn time" {
  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  f="$ORCH_ROOT/_orch/state/workers/w1.json"
  created="$(jq -r '.created' "$f")"
  updated="$(jq -r '.updated' "$f")"
  [ "$created" = "$updated" ]
}

@test "spawn.sh stamps created even when the spawn is queued (resource gate refused)" {
  jq '.thresholds.max_workers = 0' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"queued"* ]]

  f="$ORCH_ROOT/_orch/state/workers/w1.json"
  [ -f "$f" ]
  run jq -r '.status' "$f"
  [ "$output" = "queued" ]
  run jq -r '.created' "$f"
  [ "$output" != "null" ]
  [ -n "$output" ]
}
