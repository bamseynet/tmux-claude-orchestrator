#!/usr/bin/env bats
# Issue #189: heartbeat draft-valve vs the AskUserQuestion selector. Pane fixture:
# real capture, see issue189_askuser_selector.bats.

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/askuser_selector.txt"
  STUBBIN="$BATS_TEST_TMPDIR/bin"; CALLS="$BATS_TEST_TMPDIR/calls"; PANE="$BATS_TEST_TMPDIR/pane"
  mkdir -p "$STUBBIN"; : > "$CALLS"; cp "$FIX" "$PANE"
  export SESSION_NAME="orch" ORCH_WINDOW="orchestrator"
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo orch ;;
  capture-pane) cat "$PANE" ;;
  load-buffer) cat > /dev/null ;;
  show-buffer) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  # ticks cap 1: the first draft-classified tick would trip the valve at once.
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0
      | .heartbeat.max_draft_requeue_ticks = 1 | .heartbeat.max_draft_requeue_seconds = 0' \
    "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

teardown() {
  [ -n "${STATE_DIR:-}" ] && touch "$STATE_DIR/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
}

wait_for() { local _; for _ in $(seq 1 250); do "$@" && return 0; sleep 0.02; done; return 1; }

@test "heartbeat: valve that would trip does NOT type into the selector, then delivers once idle" {
  heartbeat_main & HB_PID=$!
  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"
  wait_for grep -q 'master showing a dialog; requeued events' "$LOG"
  ! grep -q 'draft safety valve tripped' "$LOG" || return 1
  ! grep -qE 'send-keys|paste-buffer' "$CALLS" || return 1
  grep -q '"id":"w1"' "$INBOX"
  # Selector answered: idle prompt, no draft -> delivered exactly once.
  printf '%s\n' '╭──────╮' '│ ❯    │' '╰──────╯' '  ? for shortcuts' > "$PANE"
  wait_for grep -q 'woke master with' "$LOG"
  touch "$STATE_DIR/.stop"; wait "$HB_PID" 2>/dev/null || true
  [ "$(grep -c 'woke master with' "$LOG")" -eq 1 ]
}
