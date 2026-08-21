#!/usr/bin/env bats
# Hermetic tests for issue #107: watchdog.sh's live_windows() must establish
# the session with session_exists() (issue #96) before its list-windows feeds
# sweep_window()'s send_prompt / reap_terminal_workers()'s clean.sh call --
# both are mutating write paths, and clean.sh in particular runs here
# UNATTENDED with no operator in the loop (`orch prune`, the dead-worker reap
# sweep).
#
# Real tmux's target resolution matches an unambiguous PREFIX (confirmed
# against tmux 3.4), not just an exact name -- so a bare `-t "$S"` list-windows
# could otherwise silently list a DIFFERENT, longer-named live session's
# windows and mutate THAT session instead of correctly treating a missing
# "$S" as "no live windows". watchdog.sh guards its main loop behind a
# "sourced vs executed" check (same pattern as watchdog_dead.bats /
# watchdog_rl_cooldown.bats), so live_windows() can be reached directly
# without starting the loop or touching a real tmux session.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ORCH_ROOT/_orch"
}

stub_tmux_prefix_hijack() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "billing" ;;
  list-windows) printf '%s\n' orchestrator w1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

@test "live_windows returns nothing for a session name that is only a PREFIX of a different live session (issue #107)" {
  stub_tmux_prefix_hijack
  export SESSION_NAME="bill"   # NOT live; "billing" is
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  run live_windows
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  ! grep -q '^list-windows' "$CALLS"
}

@test "live_windows lists windows for a session name that matches exactly" {
  stub_tmux_prefix_hijack
  export SESSION_NAME="billing"   # exact match
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  run live_windows
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1"* ]]
}
