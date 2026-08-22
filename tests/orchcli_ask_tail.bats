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
  # Scales the ORCH_ASK_TIMEOUT values below so a loaded box gets more slack
  # instead of a flake, rather than tightening/loosening the fixed values
  # themselves (issue #125).
  ASK_TIMEOUT=$((5 * ${ORCH_TEST_TIMEOUT_SCALE:-1}))
  # `orch`/`ask.sh` only fall back to their own script location for ORCH_ROOT when
  # the var isn't already set ("${ORCH_ROOT:-$here}") — a worker's shell can
  # inherit ORCH_ROOT from its own launch env, pointing at the PARENT
  # orchestrator's real toolkit. Pin it to a throwaway tmp dir so no state write
  # can ever land there (issue #68).
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  export SESSION_NAME="orch"
}

stub_tmux_no_window() {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
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
  list-sessions) echo "orch" ;;
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
  PATH="$STUBBIN:$PATH" ORCH_ASK_TIMEOUT="$ASK_TIMEOUT" run "$ASK" w1 "what is the answer?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"42, the answer"* ]]
}

@test "orch ask dispatches to ask.sh" {
  stub_tmux_with_window
  printf 'reply text\n> ready for shortcuts\n' > "$PANE_TEXT_FILE"
  PATH="$STUBBIN:$PATH" ORCH_ASK_TIMEOUT="$ASK_TIMEOUT" run "$ORCH" ask w1 "q"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reply text"* ]]
}

# --- prefix-hijack regressions (issue #96) ----------------------------------
# Real tmux's `has-session -t <name>` matches an unambiguous PREFIX (confirmed
# against tmux 3.4), not just an exact name. Model that here (never stricter
# than real tmux, same convention as hygiene_session_namespace.bats /
# issue92_named_persistent_sessions.bats / send_remote_control.bats): only
# "billing" is actually live and holds window "w1"; this install's own session
# ("bill") is NOT running. A bare `has-session`/`list-windows -t "$S"` would
# still resolve against "billing" and let ask.sh/tail read or write into a
# stranger's live pane. session_exists() must refuse instead -- and the
# assertion checks the actual hijack signal (no capture-pane/load-buffer/
# paste-buffer call ever reaches "billing"), not a status-code proxy for it.
stub_tmux_prefix_hijack() {
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\${1:-}" in
  has-session)
    [ "\${3:-}" = "billing" ] && exit 0
    [[ "billing" == "\${3:-}"* ]] && exit 0
    exit 1
    ;;
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
}

@test "ask.sh refuses to drive a DIFFERENT live session whose name is a prefix of the target (issue #96)" {
  stub_tmux_prefix_hijack
  SESSION_NAME="bill" PATH="$STUBBIN:$PATH" run "$ASK" w1 "hello?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session: bill"* ]]
  ! grep -q '^capture-pane\|^load-buffer\|^paste-buffer' "$CALLS"
}

@test "orch tail refuses to read a DIFFERENT live session whose name is a prefix of the target (issue #96)" {
  stub_tmux_prefix_hijack
  SESSION_NAME="bill" PATH="$STUBBIN:$PATH" run "$ORCH" tail w1
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session: bill"* ]]
  ! grep -q '^capture-pane' "$CALLS"
}
