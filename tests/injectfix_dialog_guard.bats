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
  # Deliberately NO paste chip: a chip is vetoed by pane_has_pending_paste()
  # BEFORE the new dialog checks, so a chip-shaped pane would pass here even
  # if the banner veto itself were broken. A short task rendered literally
  # leaves only the banner veto between this pane and is_ready()'s "❯".
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭────────────────────────────────╮
│ ❯ do the thing                 │
╰────────────────────────────────╯
  Sonnet 5  energy'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed is NOT fooled by the permission-dialog wording inside an unsent input row" {
  # A short task that merely CONTAINS the dialog header, rendered literally in
  # the input box under the banner, was never submitted -- the permission
  # check (which outranks the banner veto) must not treat it as a dialog.
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭──────────────────────────────────────────────╮
│ ❯ add a "Do you want to proceed?" prompt     │
╰──────────────────────────────────────────────╯'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "pane_has_permission_dialog matches the header inside the dialog's box border" {
  fake_tmux_set_pane "orch" "orchestrator" '╭──────────────────────────────╮
│ Bash command                 │
│ Do you want to proceed?      │
│ ❯ 1. Yes                     │
╰──────────────────────────────╯'
  run pane_has_permission_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_trust_dialog is NOT fooled by the trust wording in prose or an echoed task" {
  # The trust phrases appear mid-line in a submitted task's transcript echo
  # and in model prose -- never on a line of their own like the real dialog's
  # header/choice rows. An unanchored match here would veto inject_confirmed
  # and block every rung of spawn.sh's ladder for a worker whose task merely
  # mentions the dialog.
  fake_tmux_set_pane "orch" "orchestrator" '> fix the "Yes, I trust this folder" detection
● Done: the regex now matches trust the files in this folder and created or one you trust.'
  run pane_has_trust_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed confirms a finished task whose transcript mentions the trust dialog" {
  fake_tmux_set_pane "orch" "orchestrator" '> fix the "Yes, I trust this folder" detection
● Done: the regex now matches trust this folder.
╭────────────────────────────────╮
│ ❯                              │
╰────────────────────────────────╯'
  run inject_confirmed "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_trust_dialog detects the older 'Do you trust the files in this folder?' dialog" {
  fake_tmux_set_pane "orch" "orchestrator" '╭──────────────────────────────────────────╮
│ Do you trust the files in this folder?   │
│ ❯ 1. Yes, proceed                        │
│   2. No, exit                            │
╰──────────────────────────────────────────╯'
  run pane_has_trust_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
}

@test "pane_has_dialog is NOT fooled by a numbered 'Yes, I trust' list item without the dialog's 'No, exit' row" {
  # A --resume transcript or model prose quoting one choice as a list item.
  fake_tmux_set_pane "orch" "orchestrator" '● The dialog offers:
  1. Yes, I trust this folder
  and the session continues.'
  run pane_has_trust_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "inject_confirmed is NOT fooled by a permission header on its own continuation row of an unsent task" {
  # A short two-line task shown literally in the input box under the banner:
  # its second line is the bare header, but there is no "1. Yes" choice row.
  fake_tmux_set_pane "orch" "orchestrator" '✻ Welcome to Claude Code!
╭──────────────────────────────────────────────╮
│ ❯ add a confirm step                         │
│   Do you want to proceed?                    │
╰──────────────────────────────────────────────╯'
  run pane_has_permission_dialog "orch:orchestrator"
  [ "$status" -ne 0 ]
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}

@test "pane_has_dialog detects the --dangerously-skip-permissions startup warning (default 'No, exit')" {
  fake_tmux_set_pane "orch" "orchestrator" '╭──────────────────────────────────────────────────────────╮
│ WARNING: Claude Code running in Bypass Permissions mode  │
│ In Bypass Permissions mode, Claude Code will not ask...  │
│ ❯ 1. No, exit                                            │
│   2. Yes, I accept                                       │
╰──────────────────────────────────────────────────────────╯'
  run pane_has_dialog "orch:orchestrator"
  [ "$status" -eq 0 ]
  run inject_confirmed "orch:orchestrator"
  [ "$status" -ne 0 ]
}
