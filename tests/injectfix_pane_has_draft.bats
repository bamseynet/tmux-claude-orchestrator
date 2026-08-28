#!/usr/bin/env bats
# Hermetic tests for issue #52: pane_has_draft() must FAIL OPEN. The #38 guard
# grepped ANY of the last 15 pane lines for the input glyph and took the last
# such match as "the input line" — so a box-border / table / tool-output row
# elsewhere in the pane that happens to contain "│ >" or "❯" could be mistaken
# for the real input row, and any non-whitelisted hint text on the true input
# row was treated as an unsent draft. Either way the heartbeat requeued forever
# (orch.log: "master has an unsent draft; requeued events" on every tick).
#
# Issue #141: current Claude Code renders the model/mode footer BELOW the
# input box, so "the true prompt row is the last non-blank pane line" (the
# #52 fix above) is no longer true — the true last line is the footer, which
# never carries the glyph, and #52's rule reports "no draft" even with a full
# sentence sitting in the box. The input row is instead the LAST line whose
# VISIBLE text matches the glyph at line start
# (^[[:space:]]*($TUI_INPUT_GLYPH_REGEX)), and an empty box's filler is
# U+00A0 (NBSP, byte C2 A0) — not an ASCII space — which [[:space:]] does not
# match under this function's LC_ALL=C, so NBSP must be treated as blank too.

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

  NBSP="$(printf '\xc2\xa0')"
}

set_pane() { printf '%s\n' "$1" > "$PANE_TEXT_FILE"; }

# The exact footer Claude Code renders below the input box on this build: a
# full-width rule, a progress/model line, then the bypass-permissions hint as
# the true LAST line — none of which carry the input glyph.
footer() {
  printf '────────────────────────────────────────────────────────────\n  [██▒▒] 12%%  Opus 4.8  tmux-claude-orchestrator            /rc\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
}

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

# --- issue #141 fixtures ------------------------------------------------

@test "pane_has_draft is true for a genuine draft above the footer-below-input layout (issue #141 fixture 1)" {
  # This is the bug: the model/mode footer renders BELOW the input box, so
  # the true last pane line never carries the glyph.
  set_pane "$(printf '❯ You are the ORCHESTRATOR for this project. First read the file\n  '"'"'…/orch spawn w1 sonnet "task"'"'"', …\n  arrive automatically, prefixed [orchestrator heartbeat]. …\n%s' "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is false for a genuinely empty NBSP-filled box above the footer-below-input layout (issue #141 fixture 2)" {
  # The empty box's filler is U+00A0 (NBSP), never an ASCII space -- written
  # with an ASCII space this fixture would pass even against the broken fix
  # and prove nothing.
  set_pane "$(printf '❯ %s\n%s' "$NBSP" "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false for a scrollback echo of an earlier submitted prompt above a live empty input box (issue #141 fixture 3)" {
  # Replaces the old (unrealistic) 'true last line carries no glyph at all'
  # fixture: on this Claude Code build the input box is always rendered at
  # the bottom of the pane, so a glyph row with only prose below it and no
  # live input box at all does not occur. The realistic hazard is an OLD
  # glyph row left in scrollback above the LIVE (empty) input box, which
  # must not be mistaken for the draft.
  set_pane "$(printf '❯ can you also check the tests too\nAssistant is now responding with output\nthat just happens to end here\n❯ %s\n%s' "$NBSP" "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is true for a draft in a SIDE-BORDERED input box above the footer (rv142)" {
  # Claude Code frames the prompt row on some builds ("│ ❯ text   │" -- the
  # exact shape tests/injectfix_inject_confirmed_paste_chip.bats captures).
  # Anchoring the glyph at line start without discounting the opening border
  # matched that row not at all, so the guard went silently inert and the
  # heartbeat would paste over a real unsent draft.
  set_pane "$(printf '│ ❯ ORCHESTRATOR: do not send yet          │\n%s' "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft is true for a draft in a WIDER-PADDED side-bordered box (rv142 pass 2)" {
  # The border discount must not assume a fixed amount of box padding: with a
  # "border + at most two spaces" bound this row matched NOTHING, so the guard
  # returned "no draft" and the heartbeat would paste over a real draft. The
  # matching table-row fixtures below pin that widening it costs no #52 safety.
  set_pane "$(printf '│   ❯ real unsent draft that must survive   │\n%s' "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -eq 0 ]
}

@test "pane_has_draft still fails open on a multi-column table row whose gutter precedes the glyph (rv142 pass 2)" {
  # '│ w1 │ > 5 │' must never be taken for the input row: the glyph does not
  # follow the opening border across spaces alone. Guards the widened border.
  set_pane "$(printf 'Results:\n│ w1 │ > 5 │\nAssistant is still writing output')"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false for an EMPTY side-bordered box, even with a stale glyph echo above it (rv142)" {
  # Two halves at once: the row's trailing "│" is frame, not operator text (or
  # every idle master reports a permanent DRAFT), and the live boxed row must
  # win over the older bare-glyph scrollback echo above it (or #52's
  # requeue-forever returns).
  set_pane "$(printf '❯ can you also check the tests too\nAssistant is now responding with output\n│ ❯ %s                        │\n%s' "$NBSP" "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}

@test "pane_has_draft is false for a table row whose first column is the glyph, above a live empty box (issue #141 fixture 4)" {
  # Harder variant of the #52 table-row case: '│ > 5 │ ok │' matches the
  # glyph AT LINE START, so line-start anchoring alone does not reject it --
  # only taking the LAST such row (which is the live empty box below it) does.
  set_pane "$(printf 'Results:\n│ > 5 │ ok │\n❯ %s\n%s' "$NBSP" "$(footer)")"
  run pane_has_draft "orch:master"
  [ "$status" -ne 0 ]
}
