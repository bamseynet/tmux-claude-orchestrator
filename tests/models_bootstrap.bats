#!/usr/bin/env bats
# Hermetic tests for issue #25: bootstrap.sh must launch the master with
# models.orchestrator from config.json (when set), and fall back to plain
# `claude --dangerously-skip-permissions` (no --model) when it is unset.
#
# bootstrap.sh resolves its own dir from $BASH_SOURCE, so we run it from a
# throwaway copy of _orch/ (bootstrap.sh + lib.sh only) with heartbeat.sh and
# watchdog.sh replaced by no-op stubs — this test must never launch the real
# background loops. tmux/claude are stubbed too; tmux logs every invocation so
# we can assert on the exact launch command without a real session.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_LOG
  : > "$TMUX_LOG"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$TMUX_LOG"
case "${1:-}" in
  has-session)  exit 1 ;;                        # no existing session -> create path
  capture-pane) echo '> ready for shortcuts' ;;
  show-buffer)  exit 1 ;;                         # buffer "already delivered"
esac
exit 0
EOF

  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  TOOLKIT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$TOOLKIT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh" "$TOOLKIT/_orch/bootstrap.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$TOOLKIT/_orch/lib.sh"
  # Never launch the real background loops from a test.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/watchdog.sh"
  chmod +x "$TOOLKIT/_orch/bootstrap.sh" "$TOOLKIT/_orch/heartbeat.sh" "$TOOLKIT/_orch/watchdog.sh"
  BOOTSTRAP="$TOOLKIT/_orch/bootstrap.sh"
  export BOOTSTRAP

  export ORCH_ROOT="$TOOLKIT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch_models_test"
  mkdir -p "$PROJECT_ROOT"
}

@test "bootstrap.sh launches the master with --model from models.orchestrator" {
  jq -n '{watchdog:{enabled:false}, models:{orchestrator:"opus"}}' > "$TOOLKIT/_orch/config.json"

  run "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  run grep -F 'claude --dangerously-skip-permissions --model opus' "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "bootstrap.sh omits --model when models.orchestrator is unset" {
  jq -n '{watchdog:{enabled:false}}' > "$TOOLKIT/_orch/config.json"

  run "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  run grep -F 'claude --dangerously-skip-permissions' "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--model"* ]]
}
