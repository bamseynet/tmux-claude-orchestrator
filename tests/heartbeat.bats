#!/usr/bin/env bats
# Hermetic tests for the atomic inbox drain in _orch/heartbeat.sh (issue #10).
#
# heartbeat.sh sources lib.sh and defines the drain helpers, then only runs its
# loop when executed directly (BASH_SOURCE guard). Sourcing it here therefore
# exposes `inbox_swap` / `drain_inbox` without starting the loop, touching tmux,
# or launching `claude`. ORCH_ROOT is redirected to a temp dir so the real repo
# state is never touched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

@test "drain_inbox returns non-zero and no output when the inbox does not exist yet" {
  rm -f "$INBOX"
  run drain_inbox
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "drain_inbox returns non-zero when the inbox exists but is empty" {
  : > "$INBOX"
  run drain_inbox
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "drain_inbox emits every queued event and then reports empty" {
  printf '%s\n' '{"id":"w1","event":"turn-end"}' '{"id":"w2","event":"needs-input"}' >> "$INBOX"
  run drain_inbox
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"id":"w2"'* ]]
  # A second drain has nothing left to deliver.
  run drain_inbox
  [ "$status" -ne 0 ]
}

@test "an append racing the drain is never lost (arrives after the inbox is claimed)" {
  # Two events are already queued when the drain begins.
  printf '%s\n' 'A1' 'A2' >> "$INBOX"

  # Step 1 — the drain atomically claims the current inbox (rename-aside).
  proc="$(inbox_swap)"
  [ -n "$proc" ]
  [ -e "$proc" ]

  # Step 2 — a worker hook appends a NEW event RIGHT NOW: after the claim, before
  # the drain has read the moved-aside copy. In the old `events="$(cat "$INBOX")";
  # : > "$INBOX"` code this is exactly the event that got truncated away.
  printf '%s\n' 'B1' >> "$INBOX"

  # Step 3 — the drain reads the claimed batch. It sees only the pre-claim events.
  batch="$(cat "$proc")"
  rm -f "$proc"
  [[ "$batch" == *A1* ]]
  [[ "$batch" == *A2* ]]
  [[ "$batch" != *B1* ]]

  # The racing event survived in the live inbox and drains on the next cycle —
  # nothing was lost.
  run drain_inbox
  [ "$status" -eq 0 ]
  [[ "$output" == *B1* ]]
  [[ "$output" != *A1* ]]
  [[ "$output" != *A2* ]]
}

@test "drain_inbox recovers a batch orphaned by a crash mid-drain" {
  # Simulate a previous drain that claimed a batch (rename-aside) but crashed
  # before consuming it, leaving the .processing file behind.
  printf '%s\n' 'orphan-1' > "$INBOX.processing"
  # Meanwhile a fresh event has since arrived in the live inbox.
  printf '%s\n' 'fresh-1' >> "$INBOX"

  run drain_inbox
  [ "$status" -eq 0 ]
  [[ "$output" == *orphan-1* ]]
  [[ "$output" == *fresh-1* ]]
  # Nothing stranded afterwards.
  [ ! -e "$INBOX.processing" ]
}

@test "no event is lost when many appends race a continuous drain" {
  # A background worker appends events as fast as it can while the foreground
  # drains continuously. The old read-then-truncate drain loses whichever events
  # land between the read and the truncate; the atomic rename-aside drain cannot.
  local n=800
  : > "$INBOX"
  (
    for i in $(seq 1 "$n"); do printf 'E%d\n' "$i" >> "$INBOX"; done
  ) &
  local wpid=$!

  local collected="$BATS_TEST_TMPDIR/collected"
  : > "$collected"
  while kill -0 "$wpid" 2>/dev/null || [ -e "$INBOX" ]; do
    drain_inbox >> "$collected" || true
  done
  wait "$wpid"

  # Every appended event was drained exactly once — none dropped, none dup'd.
  local got
  got="$(sort -u "$collected" | grep -c .)"
  [ "$got" -eq "$n" ]
}

@test "heartbeat.sh drains atomically and drops the racy cat/truncate pattern" {
  hb="$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
  # The old lost-update sequence must be gone.
  ! grep -Fq 'events="$(cat "$INBOX")"' "$hb"
  # The drain must rename the inbox aside.
  grep -Eq 'mv[[:space:]]+"\$INBOX"' "$hb"
}
