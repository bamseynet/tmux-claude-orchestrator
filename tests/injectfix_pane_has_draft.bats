#!/usr/bin/env bats
# Hermetic tests for issue #52: pane_has_draft() must FAIL OPEN. The #38 guard
# grepped ANY of the last 15 pane lines for the input glyph and took the last
# such match as "the input line" — so a box-border / table / tool-output row
# elsewhere in the pane that happens to contain "│ >" or "❯" could be mistaken
# for the real input row, and any non-whitelisted hint text on the true input
# row was treated as an unsent draft. Either way the heartbeat requeued forever
# (orch.log: "master has an unsent draft; requeued events" on every tick). The
# fix inspects ONLY the true prompt row — the last non-blank pane line — and
# only reports a draft on that high-confidence match; anything else fails open.

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
}

set_pane() { printf '%s\n' "$1" > "$PANE_TEXT_FILE"; }

@test "pane_has_draft fails open when a glyph-bearing table row sits above the true (non-glyph) last line" {
  # This is exactly the #52 false-positive: a completed tool-output table row
  # contains "│ > 5 │" and is the LAST glyph-matching line in the tail, but the
  # true prompt row (bottommost line) is just a plain hint footer with no draft.
  set_pane 'Results:
│ id │ status │
│ w1 │ > 5    │
? for shortcuts'
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is still true for a genuine draft on the true (last) input row" {
  set_pane 'some earlier output
❯ can you also check the'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is false when only a placeholder/hint follows the real input glyph" {
  set_pane 'other output
❯ Try "edit <file>" to change things'
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false on an empty idle prompt as the last line" {
  set_pane 'noise
❯ '
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is true with the box-drawing input glyph variant on the true input row" {
  set_pane 'header
│ > half-typed instructio'
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is false when the true last line carries no input glyph at all" {
  set_pane '❯ some old draft that got submitted
Assistant is now responding with output
that just happens to end here'
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}
