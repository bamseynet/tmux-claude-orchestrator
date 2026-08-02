#!/usr/bin/env bats
# Hermetic tests for issue #15 point 2: a dead/absent master tmux window must not
# leave the heartbeat looping wait_ready+requeue forever with nothing noticing.
#
# heartbeat.sh guards its main loop behind a "sourced vs executed" check, so it
# can be sourced to reach master_window_alive()/master_dead_alert()/
# master_dead_clear() directly, and heartbeat_main() can be run in the background
# against a stubbed tmux (same technique as
# injectfix_heartbeat_safety_valve.bats) without a real tmux session.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  WINDOWS_FILE="$BATS_TEST_TMPDIR/windows"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  printf 'orchestrator\n' > "$WINDOWS_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-windows) cat "$WINDOWS_FILE" ;;
  capture-pane) printf '%s' '❯ ' ;;
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

wait_for() { # <predicate...>  -- poll up to 5s
  for _ in $(seq 1 250); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

@test "master_window_alive: true when the window is in tmux's list" {
  printf 'w1\norchestrator\nw2\n' > "$WINDOWS_FILE"
  run master_window_alive "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "master_window_alive: false when the window is absent (session up, window gone)" {
  printf 'w1\nw2\n' > "$WINDOWS_FILE"
  run master_window_alive "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "master_window_alive: false when the whole session is gone (list-windows fails)" {
  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "list-windows" ] && exit 1
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  run master_window_alive "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "master_dead_alert: logs once, then re-fires only after the interval elapses" {
  master_dead_alert "orch:orchestrator" 1000 60
  [ "$(grep -c 'ALERT: master window' "$LOG")" -eq 1 ]
  master_dead_alert "orch:orchestrator" 1030 60   # only +30s, interval=60 -> no re-fire
  [ "$(grep -c 'ALERT: master window' "$LOG")" -eq 1 ]
  master_dead_alert "orch:orchestrator" 1060 60   # +60s -> due
  [ "$(grep -c 'ALERT: master window' "$LOG")" -eq 2 ]
}

@test "master_dead_alert: persists first-seen across calls so the log reports total downtime" {
  master_dead_alert "orch:orchestrator" 1000 60
  master_dead_alert "orch:orchestrator" 1500 60
  grep -q 'down 500s' "$LOG"
}

@test "master_dead_clear removes the standing alert state" {
  master_dead_alert "orch:orchestrator" 1000 60
  [ -e "$STATE_DIR/.master-dead" ]
  master_dead_clear
  [ ! -e "$STATE_DIR/.master-dead" ]
}

@test "heartbeat_main requeues events (never drops them) instead of blocking on wait_ready when the master window is dead" {
  printf 'w1\n' > "$WINDOWS_FILE"   # no "orchestrator" window -> master is dead
  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"

  wait_for grep -q 'master window down; requeued events' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  # The event was requeued into the inbox, not silently dropped.
  run cat "$INBOX"
  [[ "$output" == *'"id":"w1"'* ]]
  # The standing alert was raised.
  grep -q 'ALERT: master window' "$LOG"
  # wait_ready was never given a chance to burn its own timeout polling a dead
  # target: no paste-buffer/send-keys were attempted against it.
  ! grep -q 'paste-buffer' "$CALLS"
}

@test "heartbeat_main clears the alert and resumes normal delivery once the master window comes back" {
  printf 'w1\n' > "$WINDOWS_FILE"   # start dead
  heartbeat_main &
  HB_PID=$!

  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"
  wait_for grep -q 'master window down; requeued events' "$LOG"
  [ -e "$STATE_DIR/.master-dead" ]

  printf 'w1\norchestrator\n' > "$WINDOWS_FILE"   # master window reappears
  wait_for grep -q 'paste-buffer' "$CALLS"
  # The clear runs at the top of the NEXT tick after the one that delivered (the
  # delivering tick's own top-of-loop check can still have run before the file
  # flip landed) — wait for it directly rather than racing .stop against it.
  wait_for bash -c "[ ! -e '$STATE_DIR/.master-dead' ]"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  [ ! -e "$STATE_DIR/.master-dead" ]
  ! grep -q '"id":"w1"' "$INBOX" 2>/dev/null
}
