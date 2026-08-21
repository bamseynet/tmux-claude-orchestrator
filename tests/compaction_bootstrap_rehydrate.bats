#!/usr/bin/env bats
# Hermetic tests for issue #41: bootstrap.sh nudges a REUSED (already-running)
# orchestrator session with a rehydrate summary, so a restart after a crash or a
# fresh bootstrap on top of a surviving tmux session doesn't leave the master
# with an empty transcript and no idea what's in flight.
#
# Same stubbing technique as crashrec_pid_identity.bats: tmux/claude are stubbed,
# heartbeat.sh/watchdog.sh are no-ops, bootstrap.sh is exercised end-to-end.

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
  has-session)  exit 0 ;;                        # session already exists -> reuse path
  list-sessions) echo "orch_rehydrate_test" ;;    # same: bootstrap.sh now checks this instead
  capture-pane) echo '> ready for shortcuts' ;;
  show-buffer)  exit 1 ;;                         # buffer "already delivered"
  load-buffer)
    # Record the pasted payload so we can assert on its content.
    cat > "$BATS_TEST_TMPDIR/last_buffer.txt" || true
    ;;
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
  jq -n '{watchdog:{enabled:false}}' > "$TOOLKIT/_orch/config.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/watchdog.sh"
  chmod +x "$TOOLKIT/_orch/bootstrap.sh" "$TOOLKIT/_orch/heartbeat.sh" "$TOOLKIT/_orch/watchdog.sh"

  export ORCH_ROOT="$TOOLKIT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch_rehydrate_test"
  mkdir -p "$PROJECT_ROOT"
}

@test "bootstrap.sh skips the rehydrate nudge when rehydrate.sh is absent" {
  run "$TOOLKIT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists; reusing"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/last_buffer.txt" ]
}

@test "bootstrap.sh injects a rehydrate summary into a reused session when rehydrate.sh is present" {
  cp "$BATS_TEST_DIRNAME/../_orch/rehydrate.sh" "$TOOLKIT/_orch/rehydrate.sh"
  chmod +x "$TOOLKIT/_orch/rehydrate.sh"
  mkdir -p "$TOOLKIT/_orch/state/workers"
  jq -n '{id:"w1", status:"working", model:"sonnet", task:"do the thing"}' \
    > "$TOOLKIT/_orch/state/workers/w1.json"

  run "$TOOLKIT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]

  [ -f "$BATS_TEST_TMPDIR/last_buffer.txt" ]
  grep -Fq '[rehydrate]' "$BATS_TEST_TMPDIR/last_buffer.txt"
  grep -Fq 'w1: status=working' "$BATS_TEST_TMPDIR/last_buffer.txt"
}
