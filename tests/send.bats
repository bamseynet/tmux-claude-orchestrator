#!/usr/bin/env bats
# Hermetic tests for _orch/send.sh, in particular the no-window guard path.
# tmux is replaced with an on-PATH stub, so no real tmux session is ever touched.

SEND="$BATS_TEST_DIRNAME/../_orch/send.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export SESSION_NAME="orch"
  mkdir -p "$ORCH_ROOT/_orch"
}

stub_tmux_no_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "orchestrator" ;;   # session exists, but no 'w1' window
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

stub_tmux_with_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' orchestrator w1 ;;
  capture-pane) echo '> ready for shortcuts' ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

@test "send.sh exits 1 with a clear message when the worker window is not present" {
  stub_tmux_no_window
  run "$SEND" w1 "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no worker window 'w1' in session 'orch'"* ]]
}

@test "send.sh requires a worker id argument" {
  stub_tmux_no_window
  run "$SEND"
  [ "$status" -ne 0 ]
}

@test "send.sh delivers the prompt and reports success when the window exists" {
  stub_tmux_with_window
  run "$SEND" w1 "hello there"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent to w1"* ]]
}

@test "send.sh joins multiple message words into a single prompt" {
  stub_tmux_with_window
  run "$SEND" w1 hello there friend
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent to w1"* ]]
}
