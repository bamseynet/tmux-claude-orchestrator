#!/usr/bin/env bats
# Hermetic tests for issue #15 point 1: a pidfile must be trusted only after
# confirming the PID it names is actually running the expected script, not just
# that SOME process holds that PID (`kill -0` alone is fooled by a PID reused by
# an unrelated process after a reboot).
#
# bootstrap.sh and stop.sh each define their own pid_is_expected() (duplicated —
# they don't share a sourceable file for this beyond lib.sh, which is out of
# scope for this fix). bootstrap.sh has no "sourced vs executed" guard, so it is
# exercised end-to-end via stubs (same technique as models_bootstrap.bats);
# stop.sh's copy is exercised the same way since it's a similarly flat script.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_LOG
  : > "$TMUX_LOG"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$TMUX_LOG"
case "${1:-}" in
  has-session)  exit 0 ;;   # session already exists -> skip master launch entirely
  capture-pane) echo '> ready for shortcuts' ;;
  show-buffer)  exit 1 ;;
esac
exit 0
EOF
  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  TOOLKIT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$TOOLKIT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh" "$TOOLKIT/_orch/bootstrap.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/stop.sh" "$TOOLKIT/_orch/stop.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$TOOLKIT/_orch/lib.sh"
  jq -n '{watchdog:{enabled:false}}' > "$TOOLKIT/_orch/config.json"

  LAUNCH_MARKER="$BATS_TEST_TMPDIR/heartbeat_launches"
  export LAUNCH_MARKER
  : > "$LAUNCH_MARKER"
  # A "real" heartbeat.sh that logs a launch and then lingers, so its own PID has
  # "heartbeat.sh" in its argv (via /proc/<pid>/cmdline) — the case that must be
  # trusted as already-running.
  cat > "$TOOLKIT/_orch/heartbeat.sh" <<EOF
#!/usr/bin/env bash
echo launched >> "$LAUNCH_MARKER"
sleep 100
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/watchdog.sh"
  chmod +x "$TOOLKIT/_orch/bootstrap.sh" "$TOOLKIT/_orch/stop.sh" \
           "$TOOLKIT/_orch/heartbeat.sh" "$TOOLKIT/_orch/watchdog.sh"

  export ORCH_ROOT="$TOOLKIT"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch_pid_test"
  mkdir -p "$PROJECT_ROOT"
  STATE_DIR="$TOOLKIT/_orch/state"
}

teardown() {
  [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null || true
  wait "${BG_PID:-}" 2>/dev/null || true
  pkill -f "$LAUNCH_MARKER" 2>/dev/null || true
}

wait_for() { # <predicate...>  -- poll up to 2s
  for _ in $(seq 1 100); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}

@test "bootstrap: a reused PID belonging to an unrelated process is not trusted; heartbeat is (re)launched" {
  mkdir -p "$STATE_DIR"
  sleep 100 &
  BG_PID=$!
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]

  wait_for [ -s "$LAUNCH_MARKER" ]
  [ -s "$LAUNCH_MARKER" ]
  # The pidfile was overwritten with the freshly-launched (real) heartbeat's pid,
  # not left pointing at the unrelated sleep process.
  new_pid="$(cat "$STATE_DIR/heartbeat.pid")"
  [ "$new_pid" != "$BG_PID" ]
}

@test "bootstrap: a pidfile whose PID is genuinely running heartbeat.sh is trusted; no relaunch" {
  mkdir -p "$STATE_DIR"
  "$TOOLKIT/_orch/heartbeat.sh" &
  BG_PID=$!
  wait_for [ -s "$LAUNCH_MARKER" ]
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"
  : > "$LAUNCH_MARKER"   # reset — the pre-existing launch above doesn't count

  run "$TOOLKIT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  sleep 0.3

  # Nothing new was launched: the marker (written once per real launch) stays empty.
  [ ! -s "$LAUNCH_MARKER" ]
  [ "$(cat "$STATE_DIR/heartbeat.pid")" = "$BG_PID" ]
}

@test "stop.sh: does not signal a stranger process that merely reused the recorded PID" {
  mkdir -p "$STATE_DIR"
  sleep 100 &
  BG_PID=$!
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]

  # The unrelated process must still be alive — stop.sh must not have killed it.
  kill -0 "$BG_PID" 2>/dev/null
  [ ! -e "$STATE_DIR/heartbeat.pid" ]
}

@test "stop.sh: kills a PID that is genuinely running heartbeat.sh" {
  mkdir -p "$STATE_DIR"
  "$TOOLKIT/_orch/heartbeat.sh" &
  BG_PID=$!
  wait_for [ -s "$LAUNCH_MARKER" ]
  echo "$BG_PID" > "$STATE_DIR/heartbeat.pid"

  run "$TOOLKIT/_orch/stop.sh"
  [ "$status" -eq 0 ]

  wait_for bash -c "! kill -0 $BG_PID 2>/dev/null"
  ! kill -0 "$BG_PID" 2>/dev/null
  [ ! -e "$STATE_DIR/heartbeat.pid" ]
}
