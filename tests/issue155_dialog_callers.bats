#!/usr/bin/env bats
# Issue #155 call sites beyond send/ask (see issue155_dialog_state_matrix.bats):
# the watchdog's rate-limit retry nudge and the heartbeat's master injection must
# end their ready-wait on a dialog -- one already up OR one rendering mid-wait --
# and never paste into it. Pane fixtures match the state matrix's.

SCREEN_perm=' Bash command
   rm -rf build
 Do you want to proceed?
❯ 1. Yes
  2. No'
SCREEN_busy='✻ Thinking… (esc to interrupt)
╭──────────────╮
│ ❯            │
╰──────────────╯'

# --- watchdog: rate-limit retry nudge -----------------------------------------

wd_setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root" SESSION_NAME="test" ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  SENT="$BATS_TEST_TMPDIR/sent.log"; N="$BATS_TEST_TMPDIR/n"; echo 0 > "$N"
  # shellcheck disable=SC2317  # invoked indirectly via sweep_window
  send_prompt() { echo "SEND:$*" >> "$SENT"; }
  echo 1065 > "$STATE_DIR/.rl-w1"   # cooldown long over -> rl_action says "nudge"
}

# pane_tail: capture 1 (sweep's own read) is a cleared, non-rate-limited pane;
# captures 2..$SWITCH show busy, then the permission dialog from $SWITCH+1 on.
wd_pane() {
  SWITCH="$1"
  # shellcheck disable=SC2317
  pane_tail() {
    local n; n=$(( $(cat "$N") + 1 )); echo "$n" > "$N"
    if [ "$n" -eq 1 ]; then printf '%s' "back to normal"
    elif [ "$n" -le "$SWITCH" ]; then printf '%s' "$SCREEN_busy"
    else printf '%s' "$SCREEN_perm"; fi
  }
}

@test "watchdog: no retry nudge into a dialog already on screen" {
  wd_setup; wd_pane 1
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ ! -f "$SENT" ]
  grep -q "skipping retry nudge (dialog on screen)" "$LOG"
}

@test "watchdog: no retry nudge into a dialog that renders during the ready-wait" {
  wd_setup; wd_pane 4
  SECONDS=0
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ ! -f "$SENT" ]
  grep -q "skipping retry nudge (dialog on screen)" "$LOG"
  [ "$(cat "$N")" -gt 4 ]    # the dialog really appeared mid-wait
  [ "$SECONDS" -lt 8 ]       # and ended the 10s wait early
}

@test "watchdog: a nudge skipped for a dialog is dropped, not replayed later" {
  # A permission dialog follows a fresh tool call, so the worker has resumed; a
  # deferred "re-run the exact same command" would re-run whatever it approved.
  wd_setup; wd_pane 1
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ ! -f "$SENT" ]
  [ ! -f "$STATE_DIR/.rl-w1" ]
  # Dialog answered: the next sweep sees a cleared, ready pane.
  # shellcheck disable=SC2317
  pane_tail() { printf '%s' '╭──────╮
│ ❯    │
╰──────╯'; }
  sweep_window w1 65 </dev/null >/dev/null 2>&1 || true
  [ ! -f "$SENT" ]
}

# --- heartbeat: master injection ----------------------------------------------

hb_setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"; CALLS="$BATS_TEST_TMPDIR/calls"; PANE="$BATS_TEST_TMPDIR/pane"
  mkdir -p "$STUBBIN"; : > "$CALLS"
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
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0' \
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

hb_run_with_event() {
  heartbeat_main & HB_PID=$!
  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' '{"id":"w1","event":"turn-end"}' >> "$INBOX"
}

@test "heartbeat: requeues (never pastes) when the master shows a dialog" {
  hb_setup; printf '%s\n' "$SCREEN_perm" > "$PANE"
  hb_run_with_event
  wait_for grep -q 'master showing a dialog; requeued events' "$LOG"
  touch "$STATE_DIR/.stop"; wait "$HB_PID" 2>/dev/null || true
  grep -q '"id":"w1"' "$INBOX"
  ! grep -q 'paste-buffer' "$CALLS"
}

@test "heartbeat: a dialog rendering mid-wait requeues at once, not after 45s" {
  hb_setup; printf '%s\n' "$SCREEN_busy" > "$PANE"
  hb_run_with_event
  # The event must be drained (the wait under way on the busy pane) before the
  # dialog renders, or this only re-tests the already-up case.
  wait_for test ! -s "$INBOX"
  sleep 1; printf '%s\n' "$SCREEN_perm" > "$PANE"
  wait_for grep -q 'master showing a dialog; requeued events' "$LOG"
  touch "$STATE_DIR/.stop"; wait "$HB_PID" 2>/dev/null || true
  grep -q '"id":"w1"' "$INBOX"
  ! grep -q 'paste-buffer' "$CALLS"
}
