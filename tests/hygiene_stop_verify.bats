#!/usr/bin/env bats
# Hermetic tests for issue #80: `orch down` (_orch/stop.sh) must never report
# "stopped" without verifying the processes are actually gone, must fall back to
# matching on the resolved toolkit path when the pidfile is stale/missing (never
# a bare script basename, so a second install elsewhere is never caught by
# accident — this is where #80 meets #81), and must exit non-zero naming any
# surviving PID it could not stop.
#
# Every "loop" here is a real backgrounded shell process (so kill/kill -0 behave
# exactly as in production) executing a throwaway script under a private
# ORCH_ROOT — never the real heartbeat.sh/watchdog.sh loop bodies, and never a
# real tmux session.

# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  TOOLKIT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$TOOLKIT/_orch/state"
  cp "$BATS_TEST_DIRNAME/../_orch/stop.sh" "$TOOLKIT/_orch/stop.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$TOOLKIT/_orch/lib.sh"
  chmod +x "$TOOLKIT/_orch/stop.sh"

  export ORCH_ROOT="$TOOLKIT"
  export SESSION_NAME="orch_stop_test"
  STATE_DIR="$TOOLKIT/_orch/state"

  LAUNCH_MARKER="$BATS_TEST_TMPDIR/launches"
  : > "$LAUNCH_MARKER"
}

teardown() {
  [ -n "${BG_PID:-}" ] && kill -9 "$BG_PID" 2>/dev/null || true
  wait "${BG_PID:-}" 2>/dev/null || true
  [ -n "${BG_PID2:-}" ] && kill -9 "$BG_PID2" 2>/dev/null || true
  wait "${BG_PID2:-}" 2>/dev/null || true
}

wait_for() { # <predicate...> -- poll up to 3s
  for _ in $(seq 1 150); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

real_loop() { # <name e.g. heartbeat> -> launches $TOOLKIT/_orch/<name>.sh (sleeps); pid in $LOOP_PID
  local name="$1"
  local script="$TOOLKIT/_orch/$name.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
echo launched >> "$LAUNCH_MARKER"
sleep 100
EOF
  chmod +x "$script"
  # NOTE: launch here, in the CALLER's shell, and publish the pid via $LOOP_PID.
  # Do NOT call this via $( ... ) -- command substitution runs it in a subshell that
  # exits immediately, orphaning the background child, which then dies after writing
  # its marker. That produced a test that passed locally and failed in CI.
  "$script" &
  LOOP_PID=$!
}

# A loop that ignores SIGTERM, to exercise the SIGKILL escalation path.
stubborn_loop() { # <name>
  local name="$1"
  local script="$TOOLKIT/_orch/$name.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
echo launched >> "$LAUNCH_MARKER"
trap '' TERM
sleep 100
EOF
  chmod +x "$script"
  # NOTE: launch here, in the CALLER's shell, and publish the pid via $LOOP_PID.
  # Do NOT call this via $( ... ) -- command substitution runs it in a subshell that
  # exits immediately, orphaning the background child, which then dies after writing
  # its marker. That produced a test that passed locally and failed in CI.
  "$script" &
  LOOP_PID=$!
}

# --- happy path --------------------------------------------------------------

@test "stop.sh: valid pidfile -> stops cleanly, exits 0, confirms both loops gone" {
  real_loop heartbeat; BG_PID=$LOOP_PID
  wait_for [ -s "$LAUNCH_MARKER" ]
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"
  real_loop watchdog; BG_PID2=$LOOP_PID
  wait_for kill -0 "$BG_PID2"
  echo "$BG_PID2" > "$STATE_DIR/watchdog.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped heartbeat + watchdog."* ]]

  refute_alive "$BG_PID"
  refute_alive "$BG_PID2"
  [ ! -e "$STATE_DIR/heartbeat.pid" ]
  [ ! -e "$STATE_DIR/watchdog.pid" ]
}

# --- the dangerous case: must NOT kill an unrelated process -------------------

@test "stop.sh: pidfile pointing at an unrelated live process does not kill it, and does not falsely report success for that loop being real" {
  sleep 100 &
  BG_PID=$!
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"
  # No real heartbeat.sh is running anywhere -> nothing to stop, correctly.
  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]

  kill -0 "$BG_PID" 2>/dev/null   # still alive: never touched
  [ ! -e "$STATE_DIR/heartbeat.pid" ]
}

# --- stale/missing pidfile: path-based fallback --------------------------------

@test "stop.sh: stale pidfile (dead pid) -> real loop is still found and stopped via path fallback" {
  real_loop heartbeat; BG_PID=$LOOP_PID
  wait_for [ -s "$LAUNCH_MARKER" ]
  # Pidfile points at a PID that is not (and never was) the real loop.
  dead_pid=$((BG_PID + 50000))
  echo "$dead_pid" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]

  wait_for bash -c "! kill -0 $BG_PID 2>/dev/null"
  ! kill -0 "$BG_PID" 2>/dev/null
}

@test "stop.sh: missing pidfile entirely -> path fallback still finds and stops the real loop" {
  real_loop heartbeat; BG_PID=$LOOP_PID
  wait_for [ -s "$LAUNCH_MARKER" ]
  rm -f "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]

  wait_for bash -c "! kill -0 $BG_PID 2>/dev/null"
  ! kill -0 "$BG_PID" 2>/dev/null
}

# --- escalation + honest failure reporting -------------------------------------

@test "stop.sh: a loop that ignores SIGTERM is escalated to SIGKILL and confirmed stopped" {
  stubborn_loop heartbeat; BG_PID=$LOOP_PID
  wait_for [ -s "$LAUNCH_MARKER" ]
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]
  ! kill -0 "$BG_PID" 2>/dev/null
}

@test "stop.sh never prints a false 'stopped' claim: exit 0 implies the loops are actually gone" {
  real_loop heartbeat; BG_PID=$LOOP_PID
  wait_for [ -s "$LAUNCH_MARKER" ]
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  if [ "$status" -eq 0 ]; then
    [[ "$output" == *"stopped heartbeat + watchdog."* ]]
    # inert-ok: last statement of the `if` branch that is itself the
    # @test body's final statement, so its exit status becomes the
    # test's status (issue #134 §2 Group C / #139 §3.3).
    ! kill -0 "$BG_PID" 2>/dev/null
  fi
}

# TEMPORARY: deliberate planted inert assertions to prove the new CI
# guard (issue #139 half a) can actually fail. Reverted in a follow-up
# commit on this same PR once the red run is linked in the PR body.
@test "planted: inert two-space negation" {
  ! grep -q boom "$BATS_TEST_TMPDIR/nonexistent"
  [ -e "$BATS_TEST_TMPDIR" ]
}

@test "planted: inert negation inside a for loop" {
  for f in a b; do
    ! grep -q boom "$BATS_TEST_TMPDIR/nonexistent"
  done
  [ -e "$BATS_TEST_TMPDIR" ]
}
