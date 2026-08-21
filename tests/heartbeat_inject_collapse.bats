#!/usr/bin/env bats
# End-to-end (via heartbeat_main, not just summarize_events) hermetic tests for
# issue #122: the actual send_prompt/tmux path must stay silent on a
# denylist-only batch and inject the collapsed one-liner otherwise. tmux is
# stubbed so no real window is ever touched.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  PASTED="$BATS_TEST_TMPDIR/pasted.txt"
  : > "$CALLS"
  printf '❯ ' > "$PANE_TEXT_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  capture-pane) cat "$PANE_TEXT_FILE" ;;
  load-buffer)  cat > "$PASTED" ;;
  show-buffer)  exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export SESSION_NAME="orch"
  export ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0' \
    "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

teardown() {
  touch "$STATE_DIR/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
}

wait_for() { # <predicate...>
  for _ in $(seq 1 100); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

@test "a denylist-only batch never triggers send_prompt (no paste-buffer call)" {
  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"subagent-done","ts":"t1"}' >> "$INBOX"

  wait_for grep -q 'no actionable events' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  ! grep -q 'paste-buffer' "$CALLS"
}

@test "an actionable batch injects the collapsed one-liner via the real send_prompt path" {
  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' \
    '{"id":"w1","event":"subagent-done","ts":"t1"}' \
    '{"id":"w1","event":"subagent-done","ts":"t2"}' \
    '{"id":"w2","event":"done","ts":"t3"}' >> "$INBOX"

  wait_for grep -q 'paste-buffer' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'paste-buffer' "$CALLS"
  [ -s "$PASTED" ]
  run cat "$PASTED"
  [[ "$output" == *"w2 done"* ]]
  [[ "$output" != *"subagent-done"* ]]
  [ "$(wc -l < "$PASTED")" -eq 0 ]
}
