#!/usr/bin/env bats
# Hermetic tests for issue #122: heartbeat_main() must skip the master wake
# entirely (no send_prompt at all -- no paste-buffer, no send-keys) when a
# drained batch contains only denylisted events (default: subagent-done). A
# batch containing even one non-denylisted event must still wake the master,
# and the decision must be made on the `.event` FIELD (never a raw-line
# substring match) so free-text mentions of a denylisted name in another
# event's `reason` never get mistaken for the denylisted event itself. The
# decision must also happen immediately after drain_inbox, before
# wait_ready/pane_has_draft, so a noise batch never pays the 45s wait and can
# never trip the issue-#52 draft safety valve into force-delivering itself.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  PASTED="$BATS_TEST_TMPDIR/pasted.txt"
  : > "$PASTED"
  printf '❯ \n? for shortcuts' > "$PANE_TEXT_FILE"
  export SESSION_NAME="orch"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) printf '%s\n' "$SESSION_NAME" ;;
  capture-pane)  cat "$PANE_TEXT_FILE" ;;
  load-buffer)   cat >> "$PASTED" ;;
  show-buffer)   exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
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

# Poll a condition function up to a bounded number of 20ms ticks (4s total).
wait_for() { # <predicate...>
  for _ in $(seq 1 200); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

# `! grep -q ...` asserts NOTHING in bats unless it is the very last line of the
# test: bash exempts a `!`-negated command from `set -e`, so the test sails past a
# failing absence check. Verified against bats-core 1.10.0. Use this instead --
# its failure is a plain non-zero exit that bats does catch.
refute_grep() { # <pattern> <file>
  [ "$(grep -c -- "$1" "$2" 2>/dev/null || true)" -eq 0 ]
}

start_hb() {
  heartbeat_main &
  HB_PID=$!
  wait_for grep -q 'heartbeat start' "$LOG"
}

# --- Case 1: noise-only batch -> no wake at all --------------------------------

@test "case1: a pure subagent-done batch never wakes the master" {
  start_hb
  for i in 1 2 3 4 5 6; do
    printf '{"id":"r120","event":"subagent-done","ts":"2026-08-22T10:0%s:00Z"}\n' "$i" >> "$INBOX"
  done

  # Give the loop several ticks to process the batch, then stop it.
  wait_for grep -q 'noise-only batch' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  refute_grep 'paste-buffer' "$CALLS"
  refute_grep 'send-keys' "$CALLS"
  # The batch was consumed (not left requeued forever).
  [ ! -s "$INBOX" ]
}

# --- Case 2: mixed batch -> wake, actionable event named -----------------------

@test "case2: a mixed batch wakes the master and names the actionable event" {
  start_hb
  printf '{"id":"w1","event":"subagent-done"}\n' >> "$INBOX"
  printf '{"id":"w1","event":"subagent-done"}\n' >> "$INBOX"
  printf '{"id":"w2","event":"needs-input"}\n' >> "$INBOX"

  wait_for grep -q 'send-keys' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'send-keys' "$CALLS"
  grep -q 'needs-input' "$PASTED"
}

# --- Case 3: substring trap ------------------------------------------------------

@test "case3: a merge-blocked event whose reason mentions subagent-done still wakes" {
  start_hb
  printf '%s\n' '{"id":"w1","event":"merge-blocked","reason":"waiting on subagent-done hook"}' >> "$INBOX"

  wait_for grep -q 'send-keys' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'send-keys' "$CALLS"
  grep -q 'merge-blocked' "$PASTED"
}

# --- Case 4: unknown/future event type -> wake (denylist, not allowlist) -------

@test "case4: an unrecognized future event type still wakes the master" {
  start_hb
  printf '%s\n' '{"id":"w9","event":"brand-new-event-2027"}' >> "$INBOX"

  wait_for grep -q 'send-keys' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'send-keys' "$CALLS"
}

# --- Case 5: malformed line -> fail open, still wake ----------------------------

@test "case5: a malformed non-JSON inbox line fails open and wakes the master" {
  start_hb
  printf 'not json at all\n' >> "$INBOX"

  wait_for grep -q 'send-keys' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'send-keys' "$CALLS"
}

# --- Case 6: empty denylist restores today's behaviour --------------------------

@test "case6: heartbeat.inject_denylist=[] restores full-fidelity delivery" {
  jq '.heartbeat.inject_denylist = []' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"

  start_hb
  for i in 1 2 3; do
    printf '{"id":"r120","event":"subagent-done","ts":"2026-08-22T10:0%s:00Z"}\n' "$i" >> "$INBOX"
  done

  wait_for grep -q 'send-keys' "$CALLS"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  grep -q 'send-keys' "$CALLS"
}

# --- Case 7: durable log untouched ----------------------------------------------

@test "case7: a suppressed noise-only batch never touches events.jsonl" {
  # events.jsonl is written by the emitters (report.sh etc.), never by
  # heartbeat.sh -- simulate an emitter's dual-write, then confirm heartbeat's
  # suppression path leaves the durable log byte-identical.
  mkdir -p "$STATE_DIR"
  printf '{"id":"r120","event":"subagent-done","ts":"2026-08-22T10:01:00Z"}\n' >> "$STATE_DIR/events.jsonl"
  before="$(cat "$STATE_DIR/events.jsonl")"

  start_hb
  printf '{"id":"r120","event":"subagent-done","ts":"2026-08-22T10:01:00Z"}\n' >> "$INBOX"

  wait_for grep -q 'noise-only batch' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  after="$(cat "$STATE_DIR/events.jsonl")"
  [ "$before" = "$after" ]
}

# --- Case 8: no busy-spin on continuous noise ------------------------------------

@test "case8: continuous noise-only events do not busy-spin the loop" {
  jq '.intervals.normal_seconds = 1 | .intervals.idle_seconds = 1' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"

  start_hb
  printf '{"id":"r120","event":"subagent-done"}\n' >> "$INBOX"

  sleep 1.5
  printf '{"id":"r121","event":"subagent-done"}\n' >> "$INBOX"
  sleep 1.5

  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  # With a 1s sleep per tick, ~3s of wall-clock must not produce a runaway
  # number of list-sessions calls (each tick calls it at least once via
  # master_window_alive). A busy-spin would produce hundreds/thousands.
  calls="$(grep -c 'list-sessions' "$CALLS")"
  [ "$calls" -le 20 ]
}

# --- Case 9: placement -- decided before wait_ready and the issue-#52 valve ------
#
# Cases 1-8 all pass even if the denylist check is moved to the very end of the
# branch (after master_window_alive, wait_ready and the draft valve), because
# their stub pane holds no draft: a late filter still ends up not sending. That
# is precisely the break issue #122 names third, and it leaves the defect alive
# -- every noise tick still pays the 45s wait_ready, still requeues, and still
# trips the #52 safety valve. Pin the placement directly: with a permanent pane
# draft and a low tick cap, a suppressed noise batch must produce NO requeue and
# NO valve trip at all, because the decision happened before that code ran.

@test "case9: a noise-only batch is decided before wait_ready and never touches the #52 valve" {
  printf '❯ some unsent draft text' > "$PANE_TEXT_FILE"
  jq '.heartbeat.max_draft_requeue_ticks = 2 | .heartbeat.max_draft_requeue_seconds = 3600' \
    "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  start_hb
  printf '{"id":"r120","event":"subagent-done"}\n' >> "$INBOX"

  wait_for grep -q 'noise-only batch' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  refute_grep 'paste-buffer' "$CALLS"
  refute_grep 'send-keys' "$CALLS"
  # The draft path must never have seen this batch.
  refute_grep 'requeued events' "$LOG"
  refute_grep 'safety valve tripped' "$LOG"
  [ ! -s "$INBOX" ]
}

# --- Case 10: placement -- decided before master_window_alive -------------------

@test "case10: a noise-only batch is dropped, not requeued, when the master window is dead" {
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) : ;;   # no sessions: the master window is gone
  capture-pane)  exit 1 ;;
  load-buffer)   cat >> "$PASTED" ;;
  show-buffer)   exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  start_hb
  printf '{"id":"r120","event":"subagent-done"}\n' >> "$INBOX"

  wait_for grep -q 'noise-only batch' "$LOG"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true

  refute_grep 'master window down; requeued events' "$LOG"
  [ ! -s "$INBOX" ]
}
