#!/usr/bin/env bats
# Hermetic tests for issue #128: inject_confirmed() accepts an un-submitted
# "[Pasted text]" chip sitting in the input box as proof the injected task
# landed. is_ready() cannot tell "empty prompt, task submitted" apart from
# "prompt holding an unsent paste chip" — both show the input glyph with no
# busy marker — so confirm_inject reports success on the very first poll and
# spawn.sh's #51 bare-Enter retry ladder is never reached.
#
# The tempting one-line fix (`pane_has_draft "$1" && return 1` inside
# inject_confirmed) does NOT fix the reported pane: pane_has_draft() (#52)
# inspects only the pane's last NON-BLANK line, but on a real Claude Code
# worker the footer ("Sonnet 5 <id>", "auto mode on") renders BELOW the input
# box, so the chip is never the last line and pane_has_draft reports "no
# draft". Test 1's second case pins exactly that shape.

setup() {
  export FAKE_TMUX_STATE="$BATS_TEST_TMPDIR/fake-tmux-state"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-tmux.bash"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"

  fake_tmux_add_session "orch"
}

@test "inject_confirmed is NOT fooled by an un-submitted paste chip as the last pane line" {
  fake_tmux_set_pane "orch" "orchestrator" 'some earlier output
│ ❯ [Pasted text #1 +31 lines]   │'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed is NOT fooled by a paste chip with the real footer rows rendered below it (the reported shape)" {
  fake_tmux_set_pane "orch" "orchestrator" '╭────────────────────────────────╮
│ ❯ [Pasted text #1 +31 lines]   │
╰────────────────────────────────╯
  Sonnet 5  energy
  ⏵⏵ auto mode on (shift+tab to cycle)'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed still confirms a genuinely submitted, finished pane with footer rows below an empty prompt" {
  fake_tmux_set_pane "orch" "orchestrator" 'Some earlier assistant output.
╭────────────────────────────────╮
│ ❯                               │
╰────────────────────────────────╯
  Sonnet 5  energy
  ⏵⏵ auto mode on (shift+tab to cycle)'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "inject_confirmed still confirms while the pane is actively working the task" {
  fake_tmux_set_pane "orch" "orchestrator" 'Thinking...
esc to interrupt'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

# The production shape from #128: the real startup banner is "✻ Welcome to
# Claude Code!", and that "✻" matches TUI_ACTIVE_GLYPH_REGEX. If pane_active
# is consulted before the chip guard, inject_confirmed returns "landed" on the
# banner's own glyph and the guard above is never reached -- exactly the
# never-dispatched worker the issue reports. Pins the ordering.
@test "inject_confirmed is NOT fooled by an unsent chip under the startup banner's activity glyph" {
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯ [Pasted text #1 +31 lines]   │
╰────────────────────────────────╯
  Sonnet 5  energy
  ⏵⏵ auto mode on (shift+tab to cycle)'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

# rv129 review: the chip guard must not out-vote unambiguous mid-turn evidence.
# If the TUI ever echoes the SUBMITTED paste's chip on a row that also carries
# the input glyph (a resumed session replaying its transcript is the same
# shape), scanning for a chip first would keep a worker that is demonstrably
# running the task at "not confirmed" -- earning it a duplicate full re-inject
# and a bogus spawn-failed.
@test "inject_confirmed confirms a busy pane even if a chip row is still on screen" {
  fake_tmux_set_pane "orch" "orchestrator" '❯ [Pasted text #1 +31 lines]
Thinking...
esc to interrupt'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

# Only the LAST input-glyph row can be the live input box; a chip echoed above
# it, with an empty prompt below, means the paste was submitted.
@test "inject_confirmed confirms when the chip is above an empty live input row" {
  fake_tmux_set_pane "orch" "orchestrator" '❯ [Pasted text #1 +31 lines]
  ⏺ done.
╭────────────────────────────────╮
│ ❯                               │
╰────────────────────────────────╯
  Sonnet 5  energy'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

# rv129 review: the chip guard alone is narrower than the bug class. The banner
# glyph "✻" is what makes pane_active() confirm a never-dispatched injection, so
# every shape of "banner still up, task never dispatched" -- not just the chip
# -- has to lose to pane_has_welcome(). A task short enough that Claude Code
# renders it literally instead of collapsing it into a chip is one such shape.
@test "inject_confirmed is NOT fooled by a LITERAL (uncollapsed) unsent task under the startup banner" {
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯ do the thing                  │
╰────────────────────────────────╯
  Sonnet 5  energy'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

# ...and the shape where the paste was lost outright: banner up, input box
# empty. is_ready() would call that "landed and finished fast"; the banner says
# no prompt has ever been accepted.
@test "inject_confirmed is NOT fooled by an EMPTY input box under the startup banner" {
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯                               │
╰────────────────────────────────╯
  Sonnet 5  energy'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

# Regression guard for the reorder: a spinner frame with the banner already
# scrolled away is still positive evidence the task landed.
@test "inject_confirmed still confirms a spinner frame once the banner has scrolled away" {
  fake_tmux_set_pane "orch" "orchestrator" '✽ Crunching the task
╭────────────────────────────────╮
│ ❯                               │
╰────────────────────────────────╯'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}
