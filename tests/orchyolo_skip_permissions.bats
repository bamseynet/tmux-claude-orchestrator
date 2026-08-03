#!/usr/bin/env bats
# Hermetic tests for issue #69: spawn.sh's opt-in --skip-permissions/--yolo flag,
# which launches the worker's claude with --dangerously-skip-permissions (exactly
# how bootstrap.sh launches the master) — gated on ORCH_ALLOW_SKIP_PERMISSIONS=1
# so it can't be enabled by accident. Default stays gated.
#
# tmux/git/claude are stubbed exactly as in spawn.bats; the tmux stub additionally
# logs every send-keys invocation to a file so the test can assert on the exact
# launch command that would have been typed into the worker's pane. No real tmux
# window, git worktree, or claude process is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  : > "$TMUX_LOG"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$TMUX_LOG"
case "\${1:-}" in
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
  unset ORCH_ALLOW_SKIP_PERMISSIONS
}

@test "spawn.sh without --skip-permissions never includes --dangerously-skip-permissions" {
  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  run grep -F "claude --model" "$TMUX_LOG"
  [ "$status" -eq 0 ]
  ! grep -Fq -- "--dangerously-skip-permissions" "$TMUX_LOG"
}

@test "spawn.sh --skip-permissions with ORCH_ALLOW_SKIP_PERMISSIONS=1 includes --dangerously-skip-permissions" {
  export ORCH_ALLOW_SKIP_PERMISSIONS=1
  run "$SPAWN" w2 sonnet "do the thing" --no-worktree --skip-permissions
  [ "$status" -eq 0 ]
  run grep -F "claude --model" "$TMUX_LOG"
  [ "$status" -eq 0 ]
  grep -Fq -- "--dangerously-skip-permissions" "$TMUX_LOG"
}

@test "spawn.sh --yolo alias with ORCH_ALLOW_SKIP_PERMISSIONS=1 includes --dangerously-skip-permissions" {
  export ORCH_ALLOW_SKIP_PERMISSIONS=1
  run "$SPAWN" w3 sonnet "do the thing" --no-worktree --yolo
  [ "$status" -eq 0 ]
  grep -Fq -- "--dangerously-skip-permissions" "$TMUX_LOG"
}

@test "spawn.sh --skip-permissions without the env ack errors out and spawns nothing" {
  run "$SPAWN" w4 sonnet "do the thing" --no-worktree --skip-permissions
  [ "$status" -ne 0 ]
  [[ "$output" == *"ORCH_ALLOW_SKIP_PERMISSIONS=1"* ]]
  [ ! -s "$TMUX_LOG" ]
  [ ! -f "$ORCH_ROOT/_orch/state/workers/w4.json" ]
}

@test "spawn.sh --yolo without the env ack errors out" {
  run "$SPAWN" w5 sonnet "do the thing" --no-worktree --yolo
  [ "$status" -ne 0 ]
  [[ "$output" == *"ORCH_ALLOW_SKIP_PERMISSIONS=1"* ]]
}
