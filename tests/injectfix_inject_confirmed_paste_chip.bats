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
