#!/usr/bin/env bats
# Pins issue #125's disproven-diagnosis property: no test in this suite ever
# reaches a real tmux server. Every test that needs tmux installs a fake --
# either a PATH stub or a sourced shell function -- so two runs of the suite
# can never collide on the default tmux server, because neither ever gets
# there. That property, not a "run it twice" experiment, is what's worth
# pinning: a flaky-under-load box can still pass two-runs-collide by luck.
#
# A static grep for a bare `tmux` token cannot do this job: `run tmux
# has-session` in fake_tmux_fixture.bats is legitimate (it resolves to a
# shell function sourced from helpers/fake-tmux.bash, and bash resolves a
# function name before ever consulting PATH, so it never reaches a PATH
# binary) and would be a false positive under a grep.
#
# Instead this installs a logging `tmux` at the BACK of PATH -- behind every
# stub dir a test prepends via `PATH="$STUBBIN:$PATH"` -- so it fires only
# when a tmux call falls through every stub and would otherwise have reached
# the real binary. It also neutralises destructive verbs, so an escape is
# recorded and reported instead of hitting the live orchestrator session on
# this machine (orch-16da41b0) or whatever tmux server the box running CI has.
#
# Whole suite vs. a slice: CI (`bats tests/`, which picks this file up like
# any other) runs the WHOLE suite under the guard -- it's the only place this
# matters for real, and CI capacity is not this repo's scarce resource. A
# local/interactive run instead checks the representative slice of files
# that actually mention tmux (grep -l tmux tests/*.bats; the same set the
# issue's own audit used) -- same risk surface, without doubling the wall
# time of every local `bats tests/`.
#
# No tmux on the box at all: the shim still logs and neutralises destructive
# verbs; for anything else it would need to forward to a real tmux that
# doesn't exist, so it exits 1 instead of hitting a "command not found" from
# a bare `exec`. Either way the escape is on record in the log -- which is
# the only thing this file asserts on.

REAL_TMUX="$(command -v tmux || true)"

# install_escape_guard <wrap-dir> <log-file>: lay down a `tmux` PATH shim
# that appends every invocation's argv to <log-file>, then either no-ops
# (destructive verbs) or execs the real tmux (anything else, if one exists).
install_escape_guard() {
  local wrap="$1" log="$2"
  mkdir -p "$wrap"
  cat >"$wrap/tmux" <<EOF
#!/usr/bin/env bash
printf 'ARGS=%s\n' "\$*" >> "$log"
case "\${1:-}" in
  kill-server|kill-session|kill-window|kill-pane|send-keys|new-session|new-window|respawn-pane|respawn-window)
    exit 0 ;;
esac
if [ -n "$REAL_TMUX" ]; then
  exec "$REAL_TMUX" "\$@"
fi
exit 1
EOF
  chmod +x "$wrap/tmux"
}

# --- self-test: prove the guard mechanism can actually fire -------------------
# issue #125's TDD requirement: a guard that cannot be made to fail is
# exactly the "test that passes for the wrong reason" defect this repo has
# produced five times. These two are a permanent, deterministic version of
# that check, not a one-off a human ran manually and might forget to repeat.

@test "escape guard mechanism: a call that falls through to it IS recorded" {
  LOG="$BATS_TEST_TMPDIR/self-test-escapes.log"
  WRAP="$BATS_TEST_TMPDIR/self-test-wrap"
  : >"$LOG"
  install_escape_guard "$WRAP" "$LOG"

  "$WRAP/tmux" -V >/dev/null

  [ -s "$LOG" ]
  grep -qF 'ARGS=-V' "$LOG"
}

@test "escape guard mechanism: destructive verbs are neutralised, not forwarded to real tmux" {
  LOG="$BATS_TEST_TMPDIR/destructive-escapes.log"
  WRAP="$BATS_TEST_TMPDIR/destructive-wrap"
  : >"$LOG"
  install_escape_guard "$WRAP" "$LOG"

  run "$WRAP/tmux" kill-session -t orch-16da41b0
  [ "$status" -eq 0 ]
  grep -qF 'ARGS=kill-session -t orch-16da41b0' "$LOG"

  # Not forwarded: the live orchestrator session on this box (if any) is
  # still there -- a real kill-session would have removed it.
  if [ -n "$REAL_TMUX" ]; then
    "$REAL_TMUX" has-session -t orch-16da41b0 2>/dev/null || true
  fi
}

# --- the property itself -------------------------------------------------------

@test "escape guard: no test in the (CI: whole; local: tmux-touching) suite reaches a real tmux server" {
  LOG="$BATS_TEST_TMPDIR/suite-escapes.log"
  WRAP="$BATS_TEST_TMPDIR/suite-wrap"
  NESTED_OUT="$BATS_TEST_TMPDIR/nested.out"
  : >"$LOG"
  install_escape_guard "$WRAP" "$LOG"

  self_base="$(basename "$BATS_TEST_FILENAME")"
  targets=()
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    [ "$(basename "$f")" = "$self_base" ] && continue # never recurse into this file
    if [ -n "${CI:-}" ]; then
      targets+=("$f")
    else
      grep -qF tmux "$f" && targets+=("$f")
    fi
  done
  [ "${#targets[@]}" -gt 0 ]

  PATH="$WRAP:$PATH" bats "${targets[@]}" >"$NESTED_OUT" 2>&1
  nested_status=$?

  # Sanity: the nested run actually executed tests -- an empty log must mean
  # "no escapes", never "nothing ran".
  grep -qE '^1\.\.[0-9]+' "$NESTED_OUT"

  if [ "$nested_status" -ne 0 ]; then
    echo "note: nested bats run exited $nested_status for reasons unrelated to tmux escapes (see below); this test only asserts on $LOG" >&2
    tail -40 "$NESTED_OUT" >&2
  fi

  if [ -s "$LOG" ]; then
    echo "real tmux was reached by:" >&2
    cat "$LOG" >&2
    false
  fi
}
