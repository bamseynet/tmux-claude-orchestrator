#!/usr/bin/env bats
# Hermetic tests for issues #132/#133: Claude Code's tool-permission dialog and
# startup folder-trust dialog are both a page of choices with a highlighted
# default that Enter selects -- not "submit the input box". Before this fix,
# inject_confirmed() had no signal for either: a permission dialog (which can
# only render AFTER a prompt is accepted) was wrongly treated as "not
# confirmed" whenever the startup banner was still in the 25-row capture
# alongside it (#133's reported false negative), and the trust dialog's
# highlighted-choice arrow ("❯ No, exit") matched the same bare-"❯" regex
# is_ready() uses for a real input prompt, so nothing stopped it being
# misread as "landed" either.

setup() {
  export FAKE_TMUX_STATE="$BATS_TEST_TMPDIR/fake-tmux-state"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/fake-tmux.bash"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"

  fake_tmux_add_session "orch"
}

# --- pane_has_permission_dialog / pane_has_trust_dialog / pane_has_dialog ----------

@test "pane_has_permission_dialog detects the tool-permission dialog" {
  fake_tmux_set_pane "orch" "orchestrator" 'Do you want to proceed?
 1. Yes
 2. No'
  run pane_has_permission_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_permission_dialog is false on an ordinary ready pane" {
  fake_tmux_set_pane "orch" "orchestrator" '╭──────╮
│ ❯     │
╰──────╯'
  run pane_has_permission_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "pane_has_trust_dialog detects the folder-trust dialog (issue #133 production shape)" {
  fake_tmux_set_pane "orch" "orchestrator" ' Quick safety check: Is this a project you created or one you trust? ...
 Claude Code'"'"'ll be able to read, edit, and execute files here.
 Security guide
❯ No, exit
  Yes, I trust this folder
 Enter to confirm · Esc to cancel'
  run pane_has_trust_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_trust_dialog is false on an ordinary ready pane" {
  fake_tmux_set_pane "orch" "orchestrator" '❯ '
  run pane_has_trust_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "pane_has_dialog is true for either dialog" {
  fake_tmux_set_pane "orch" "orchestrator" 'Do you want to proceed?
 1. Yes
 2. No'
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]

  fake_tmux_set_pane "orch" "orchestrator" '❯ No, exit
  Yes, I trust this folder'
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_dialog is false with neither dialog on screen" {
  fake_tmux_set_pane "orch" "orchestrator" 'Thinking...
esc to interrupt'
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
}

# --- inject_confirmed(): permission dialog is positive evidence (issue #133) -------

@test "inject_confirmed treats a visible permission dialog as landed even with the startup banner still on screen" {
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!

Do you want to proceed?
 1. Yes
 2. No'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "inject_confirmed treats a visible permission dialog as landed with no banner present" {
  # Deliberately no "❯" or other TUI_READY_REGEX glyph anywhere in this pane,
  # so a green result here can only come from the permission-dialog check --
  # not from falling through to is_ready() by coincidence.
  fake_tmux_set_pane "orch" "orchestrator" 'Bash command
Do you want to proceed?
 1. Yes
 2. No'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

# --- inject_confirmed(): trust dialog is NEVER positive evidence (issue #133) ------

@test "inject_confirmed is NOT fooled by the trust dialog's highlighted-choice arrow into is_ready's bare glyph match" {
  fake_tmux_set_pane "orch" "orchestrator" 'Quick safety check: Is this a project you created or one you trust?
❯ No, exit
  Yes, I trust this folder
Enter to confirm · Esc to cancel'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed is NOT fooled by the trust dialog even without the startup banner" {
  fake_tmux_set_pane "orch" "orchestrator" 'created or one you trust
❯ No, exit
  Yes, I trust this folder'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

# --- regression guard (issue #128): banner veto still refuses a never-dispatched --
# injection when NEITHER dialog is on screen -- the pre-existing #128 behaviour
# must survive the new checks being inserted ahead of it.

@test "inject_confirmed still refuses a never-dispatched injection under the banner when no dialog is present (#128 regression guard)" {
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯ [Pasted text #1 +31 lines]   │
╰────────────────────────────────╯
  Sonnet 5  energy'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}
