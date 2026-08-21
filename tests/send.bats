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
  list-sessions) echo "orch" ;;
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
  list-sessions) echo "orch" ;;
  list-windows) printf '%s\n' orchestrator w1 ;;
  capture-pane) echo '> ready for shortcuts' ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

# --- prefix-hijack regression (issue #107) ----------------------------------
# Real tmux's target resolution matches an unambiguous PREFIX (confirmed
# against tmux 3.4), not just an exact name -- issue #96 fixed the read-only
# existence checks against this, but send.sh's paste-buffer/send-keys (the
# actual mutation) still passed a bare `-t "$S"`/`-t "$S:$id"` straight through,
# so it could land in a DIFFERENT, longer-named live session instead of
# failing. Only "billing" is actually live and holds window "w1"; this
# install's own session ("bill") is NOT running. Assert the real hijack
# signal -- no load-buffer/paste-buffer/send-keys call ever reaches
# "billing" -- not a status-code proxy for it.
stub_tmux_prefix_hijack() {
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "billing" ;;
  list-windows) printf '%s\n' orchestrator w1 ;;
  capture-pane) echo "> ready for shortcuts" ;;
  load-buffer) cat >/dev/null ;;
  paste-buffer) exit 0 ;;
  show-buffer) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

@test "send.sh refuses to drive a DIFFERENT live session whose name is a prefix of the target (issue #107)" {
  stub_tmux_prefix_hijack
  SESSION_NAME="bill" PATH="$STUBBIN:$PATH" run "$SEND" w1 "hello?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session: bill"* ]]
  ! grep -q '^load-buffer\|^paste-buffer\|^send-keys' "$CALLS"
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
