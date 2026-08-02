#!/usr/bin/env bats
# Hermetic tests for issue #52's safety valve: heartbeat_main() must never requeue
# for a "draft" indefinitely. Even if pane_has_draft() keeps reporting true (e.g. a
# stuck/misdetected pane), after config.heartbeat.max_draft_requeue_ticks
# consecutive ticks it must force-deliver the event anyway. tmux is stubbed so no
# real tmux window is ever touched; intervals are zeroed so the real loop ticks
# fast enough to observe within the test.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  printf '❯ some unsent draft text' > "$PANE_TEXT_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  capture-pane) cat "$PANE_TEXT_FILE" ;;
  load-buffer)  cat > /dev/null ;;
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
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0
      | .heartbeat.max_draft_requeue_ticks = 3 | .heartbeat.max_draft_requeue_seconds = 3600' \
    "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

teardown() {
  touch "$STATE_DIR/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
}

# Poll a condition function up to a bounded number of 20ms ticks (2s total).
wait_for() { # <predicate...>
  for _ in $(seq 1 100); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

@test "config.json accepts a heartbeat.max_draft_requeue_ticks/seconds knob" {
  run jq -r '.heartbeat.max_draft_requeue_ticks' "$ORCH_ROOT/_orch/config.json"
  [ "$output" = "3" ]
  run jq -r '.heartbeat.max_draft_requeue_seconds' "$ORCH_ROOT/_orch/config.json"
  [ "$output" = "3600" ]
}

@test "heartbeat_main forces delivery after max_draft_requeue_ticks consecutive draft ticks even though the draft never clears" {
  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"

  wait_for grep -q 'paste-buffer' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  # It must have been requeued (draft detected) at least once before delivery —
  # the valve waits for the tick cap, it does not deliver on the very first tick.
  requeues="$(grep -c 'unsent draft; requeued events' "$LOG")"
  [ "$requeues" -ge 2 ]

  # The valve tripped and force-delivered.
  grep -q 'draft safety valve tripped' "$LOG"
  grep -q 'paste-buffer' "$CALLS"
  # The event was actually delivered, not silently dropped.
  ! grep -q '"id":"w1"' "$INBOX" 2>/dev/null
}

@test "heartbeat_main delivers immediately (no valve trip) once the draft is gone" {
  printf '❯ ' > "$PANE_TEXT_FILE"

  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w2","event":"turn-end"}' >> "$INBOX"

  wait_for grep -q 'paste-buffer' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  ! grep -q 'draft safety valve tripped' "$LOG"
  ! grep -q 'unsent draft; requeued events' "$LOG"
  grep -q 'paste-buffer' "$CALLS"
}
