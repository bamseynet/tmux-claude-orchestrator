#!/usr/bin/env bats
# Hermetic tests for pane_has_draft() in _orch/lib.sh (issue #38, hardened by
# #101): a heartbeat injection must be able to tell an empty idle input line
# apart from one holding the operator's unsent draft -- and, since #101, apart
# from Claude Code's own dim suggested-next-prompt ghost text. tmux is stubbed
# so no real tmux window is touched.

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  printf '' > "$PANE_TEXT_FILE"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane) cat "$PANE_TEXT_FILE" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"

  ESC="$(printf '\x1b')"
}

set_pane() { printf '%s\n' "$1" > "$PANE_TEXT_FILE"; }

@test "pane_has_draft is false on an empty idle prompt" {
  set_pane '❯ '
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false on the placeholder hint text" {
  set_pane '❯ Try "edit <file>" to change things'
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is true when operator text follows the prompt glyph" {
  set_pane '❯ can you also check the'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is true with the box-drawing input glyph variant" {
  set_pane '│ > half-typed instructio'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

# --- issue #101: dim ghost text vs. bright real input -----------------------
# SGR sequences captured live from real worker panes via `tmux capture-pane -p
# -e` (see issue #101's evidence section): the ghost suggestion carries the
# dim/faint attribute (ESC[2m); real operator/orch-send input renders bright
# white (38;5;231) on a highlighted background (48;5;237) -- neither escape
# includes "2m" as a standalone SGR field, so the two are unambiguous under
# the fix's regex. These tests fail if pane_has_draft() goes back to stripping
# escapes before ever looking at them (the pre-#101 behavior): both cases would
# then reduce to the exact same plain text as "pane_has_draft is true when
# operator text follows the prompt glyph" above and both would report a draft,
# so a test that only checked the ghost case in isolation couldn't tell "the
# fix suppressed it" apart from "the fix suppresses everything" -- asserting
# the real-input case stays TRUE alongside the ghost case FALSE is what proves
# the fix discriminates rather than over-suppressing.

@test "pane_has_draft is false for Claude Code's dim ghost-suggestion text (issue #101)" {
  set_pane "❯ ${ESC}[39m${ESC}[2mFile the follow-up issue for the bash-3.2 CI gap.${ESC}[0m"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is true for bright real operator input with the same glyph (issue #101)" {
  set_pane "❯ ${ESC}[38;5;239m${ESC}[48;5;237m${ESC}[38;5;231mORCHESTRATOR: PR #99 is MERGED as 2d78424 ..."
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft still reports a draft for dim-looking PLAIN TEXT that merely mentions ESC[2m (issue #101 anti-false-positive)" {
  # The dim check must key off the actual escape BYTE, not the literal string
  # "ESC[2m" appearing as ordinary characters in the operator's own draft text.
  set_pane '❯ can you double check the ESC[2m handling in strip_ansi'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft fails toward DRAFT (not toward no-draft) when no color info is available at all (issue #101)" {
  # Simulates an old tmux where -e is silently ignored (capture-pane returns
  # plain text with no escapes at all, same as this file's pre-#101 tests) --
  # the deliberate direction per the issue: never silently clobber a real
  # unsent draft just because color couldn't be read, even at the cost of
  # occasionally over-detecting a ghost suggestion in that degraded case.
  set_pane '❯ can you also check the'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}
