#!/usr/bin/env bats
# Hermetic tests for issue #18: `orch tail <id>` (pane_tail exposed on the CLI)
# and `orch ask <id> "q"` (send -> wait_ready -> capture reply). tmux is
# replaced with an on-PATH stub, so no real tmux session/window/claude process
# is ever touched.

ORCH="$BATS_TEST_DIRNAME/../orch"
ASK="$BATS_TEST_DIRNAME/../_orch/ask.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  export ORCH_ROOT="$BATS_TEST_DIRNAME/.."
  export SESSION_NAME="orch"
}

stub_tmux_no_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "orchestrator" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
}

# capture-pane always prints "$PANE_TEXT_FILE"'s contents, so a test can flip
# the simulated reply between "send the question" and "worker answers ready".
stub_tmux_with_window() {
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  printf '%s\n' "> ready for shortcuts" > "$PANE_TEXT_FILE"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' orchestrator w1 ;;
  capture-pane) cat "$PANE_TEXT_FILE" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
}

@test "orch tail requires a worker id" {
  stub_tmux_no_window
  PATH="$STUBBIN:$PATH" run "$ORCH" tail
  [ "$status" -ne 0 ]
}

@test "orch tail fails clearly when the worker window is not present" {
  stub_tmux_no_window
  PATH="$STUBBIN:$PATH" run "$ORCH" tail w1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no worker window 'w1' in session 'orch'"* ]]
}

@test "orch tail prints the worker's recent pane output" {
  stub_tmux_with_window
  printf 'line one\nline two\n> ready for shortcuts\n' > "$PANE_TEXT_FILE"
  PATH="$STUBBIN:$PATH" run "$ORCH" tail w1
  [ "$status" -eq 0 ]
  [[ "$output" == *"line one"* ]]
  [[ "$output" == *"line two"* ]]
}

@test "ask.sh exits 1 with a clear message when the worker window is not present" {
  stub_tmux_no_window
  PATH="$STUBBIN:$PATH" run "$ASK" w1 "hello?"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no worker window 'w1' in session 'orch'"* ]]
}

@test "ask.sh requires a question argument" {
  stub_tmux_no_window
  PATH="$STUBBIN:$PATH" run "$ASK" w1
  [ "$status" -ne 0 ]
}

@test "ask.sh sends the question and prints the worker's reply once ready" {
  stub_tmux_with_window
  printf '42, the answer\n> ready for shortcuts\n' > "$PANE_TEXT_FILE"
  PATH="$STUBBIN:$PATH" ORCH_ASK_TIMEOUT=5 run "$ASK" w1 "what is the answer?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"42, the answer"* ]]
}

@test "orch ask dispatches to ask.sh" {
  stub_tmux_with_window
  printf 'reply text\n> ready for shortcuts\n' > "$PANE_TEXT_FILE"
  PATH="$STUBBIN:$PATH" ORCH_ASK_TIMEOUT=5 run "$ORCH" ask w1 "q"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reply text"* ]]
}
