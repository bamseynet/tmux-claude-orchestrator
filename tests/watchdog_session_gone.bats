#!/usr/bin/env bats
# Hermetic tests for issue #114: the watchdog's dead-worker sweep could not
# distinguish "this one worker's window died" from "the whole tmux session is
# gone" (e.g. the operator killed/exited it, orphaning the nohup'd heartbeat
# and watchdog loops). In the second case `tmux list-windows -t "$S"` fails,
# but the old `2>/dev/null` capture turned that failure into an empty string
# -- INDISTINGUISHABLE from "session up, but somehow zero windows" -- so
# dead_sweep() treated every active worker as orphaned simultaneously and
# prune_dead_worktree destroyed every worktree/branch, including uncommitted
# work, within one debounce window. live_windows() must fail loudly (return
# 1) when the session itself is gone, so the main loop can skip the sweep
# entirely that tick instead of asking dead_sweep to reason about a windows
# list it cannot trust.
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we
# can source it to reach live_windows() without starting the loop. A stub
# `tmux` bash function (defined before sourcing) fakes list-sessions/
# list-windows so this runs fully offline, no real tmux server involved.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"

  # Stateful-enough stub: SESSION_UP=1 means a session named EXACTLY
  # "$SESSION_NAME" exists; SESSION_UP=0 simulates a killed/exited session (or
  # server). SESSION_UP=prefix simulates our exact session being gone while a
  # DIFFERENTLY-named session that merely starts with the same string is
  # still alive -- real tmux resolves `-t <name>` against an unambiguous
  # PREFIX match too (not just an exact name), so a naive "does list-windows
  # succeed" check could be fooled into sweeping a live worker as if it were
  # our (actually gone) session. This is what session_exists()'s exact-match
  # list-sessions scan (already used elsewhere for #92/#96) exists to prevent.
  SESSION_UP=1
  tmux() {
    case "${1:-}" in
      list-sessions)
        case "$SESSION_UP" in
          1) printf '%s\n' "$SESSION_NAME" ;;
          prefix) printf '%s\n' "${SESSION_NAME}-other" ;;
        esac
        return 0
        ;;
      list-windows)
        case "$SESSION_UP" in
          1)
            printf '%s\n' "orchestrator" "w1"
            return 0
            ;;
          prefix)
            # Real tmux: -t "$SESSION_NAME" ambiguously prefix-matches the
            # live "${SESSION_NAME}-other" session and succeeds against it.
            printf '%s\n' "orchestrator" "other-session-window"
            return 0
            ;;
          *)
            # Real tmux: list-windows against a nonexistent session fails.
            return 1
            ;;
        esac
        ;;
    esac
    return 0
  }
  export -f tmux

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
}

@test "live_windows: session exists -> prints windows, succeeds" {
  SESSION_UP=1
  run live_windows
  [ "$status" -eq 0 ]
  [[ "$output" == *"orchestrator"* ]]
  [[ "$output" == *"w1"* ]]
}

@test "live_windows: session gone -> fails instead of returning an empty list" {
  SESSION_UP=0
  run live_windows
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "live_windows: our exact session is gone -> fails even if a prefix-matching session is alive" {
  SESSION_UP=prefix
  run live_windows
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "issue #114: main-loop tick must not run dead_sweep against an unreachable session" {
  mkdir -p "$WORKERS_DIR"
  printf '{"id":"w1","status":"working","updated":"x"}\n' > "$WORKERS_DIR/w1.json"

  SESSION_UP=0
  # This is exactly what a tick in the main loop must do: only call
  # dead_sweep with a windows list it actually trusts. Simulate two ticks
  # (past DEAD_CONFIRM_TICKS) with the session unreachable the whole time.
  for _ in 1 2 3; do
    if windows="$(live_windows)"; then
      dead_sweep "$windows"
    fi
  done

  run jq -r .status "$WORKERS_DIR/w1.json"
  [ "$output" = "working" ]
  [ ! -s "$INBOX" ]
}
