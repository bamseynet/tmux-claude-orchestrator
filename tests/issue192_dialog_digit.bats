#!/usr/bin/env bats
# Issue #192: `orch send <id> N` PASTED the digit (+Enter) at permission and
# trust dialogs; both ignore a paste, so the Enter took the highlighted default
# ("1. Yes" approves a tool call; "No, exit" kills claude).
#
# Fixture provenance: permission_dialog_4opt.txt and trust_dialog.txt are REAL
# captures (Claude Code 2.1.310, tmux 3.4, 120x40, throwaway `tmux -L` socket,
# scratch HOME) quoted in the body of issue #192. permission_dialog_2opt.txt is
# SYNTHETIC: the 4-option capture hand-trimmed to two options.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  FX="$BATS_TEST_DIRNAME/fixtures"
}

stub_tmux() { # <screen file>
  STUBBIN="$BATS_TEST_TMPDIR/bin"; CALLS="$BATS_TEST_TMPDIR/calls"; PANE="$BATS_TEST_TMPDIR/pane"
  mkdir -p "$STUBBIN"; : > "$CALLS"; cp "$1" "$PANE"
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo orch ;;
  list-windows) printf '%s\n' orchestrator w ;;
  capture-pane) cat "$PANE" ;;
  load-buffer) cat > /dev/null ;;
  show-buffer) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/tmux"
  export PATH="$STUBBIN:$PATH" SESSION_NAME=orch
}

send() { run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w "$@"; }
no_keys_sent() { ! grep -qE 'send-keys|paste-buffer|load-buffer' "$CALLS"; }

@test "permission: a shown digit is typed as one literal key, no paste, no Enter" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send 4
  [ "$status" -eq 0 ]
  [[ "$output" == *"typed option 4"* ]]
  grep -qx 'send-keys -t orch:w -l 4' "$CALLS"
  ! grep -qE 'paste-buffer|load-buffer|Enter' "$CALLS"
}

@test "permission: option 1 is typed too" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send 1
  [ "$status" -eq 0 ]
  grep -qx 'send-keys -t orch:w -l 1' "$CALLS"
}

@test "permission: option 5 (not shown) is refused" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send 5
  [ "$status" -ne 0 ]
  no_keys_sent
}

@test "permission: free text is refused" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send hello
  [ "$status" -ne 0 ]
  no_keys_sent
}

@test "permission: option 4 on a 2-option dialog is refused" {
  stub_tmux "$FX/permission_dialog_2opt.txt"
  send 4
  [ "$status" -ne 0 ]
  no_keys_sent
}

@test "permission: option 2 on a 2-option dialog is typed" {
  stub_tmux "$FX/permission_dialog_2opt.txt"
  send 2
  [ "$status" -eq 0 ]
  grep -qx 'send-keys -t orch:w -l 2' "$CALLS"
}

@test "trust: 1 and 2 are refused, nothing sent, message names the trust dialog" {
  stub_tmux "$FX/trust_dialog.txt"
  for n in 1 2; do
    send "$n"
    [ "$status" -ne 0 ]
    [[ "$output" == *"trust dialog"* ]]
    no_keys_sent
  done
}

# Race: the permission dialog is gone (or became a selector) by the time the
# send re-captures the pane; nothing may be pasted or typed.
@test "race: permission dialog replaced by an idle pane before the send -> refused" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  printf '%s\n' '╭──────╮' '│ ❯    │' '╰──────╯' > "$BATS_TEST_TMPDIR/idle"
  sed -i "s|capture-pane) cat \"$PANE\" ;;|capture-pane) n=\$(( \$(cat $BATS_TEST_TMPDIR/n 2>/dev/null \|\| echo 0) + 1 )); echo \$n > $BATS_TEST_TMPDIR/n; if [ \$n -ge 3 ]; then cat $BATS_TEST_TMPDIR/idle; else cat \"$PANE\"; fi ;;|" "$STUBBIN/tmux"
  grep -q 'idle' "$STUBBIN/tmux"
  send 4
  [ "$status" -ne 0 ]
  no_keys_sent
}

# The command preview sits in the same blank-free block as the options, so a
# numbered line in it must not vouch for an option the dialog does not have.
@test "permission: a numbered line in the command preview does not vouch for option 3" {
  printf '%s\n' ' Bash command' '   cat <<EOF' '   3. step three' '   EOF' \
    ' Do you want to proceed?' ' ❯ 1. Yes' '   2. No' ' Esc to cancel · Tab to amend' \
    > "$BATS_TEST_TMPDIR/preview"
  stub_tmux "$BATS_TEST_TMPDIR/preview"
  send 3
  [ "$status" -ne 0 ]
  no_keys_sent
}

# The repurposed #155 chip-echo test now covers the trust dialog; keep the
# permission-dialog half: an echoed chip above the dialog must not block it.
@test "permission: a chip echoed above the dialog does not block the typed answer" {
  { echo '❯ [Pasted text #1 +5 lines]'; cat "$FX/permission_dialog_2opt.txt"; } > "$BATS_TEST_TMPDIR/echo"
  stub_tmux "$BATS_TEST_TMPDIR/echo"
  send 2
  [ "$status" -eq 0 ]
  grep -qx 'send-keys -t orch:w -l 2' "$CALLS"
}

# Race, the case the "screen changed" guard exists for: the permission dialog
# becomes an AskUserQuestion selector that also shows option 4. Typing 4 there
# would pick a selector answer nobody saw; the idle-pane race above is caught
# by pane_option_visible alone and does not exercise this guard.
@test "race: permission dialog replaced by a selector showing the option -> refused" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  sed -i "s|capture-pane) cat \"$PANE\" ;;|capture-pane) n=\$(( \$(cat $BATS_TEST_TMPDIR/n 2>/dev/null \|\| echo 0) + 1 )); echo \$n > $BATS_TEST_TMPDIR/n; if [ \$n -ge 3 ]; then cat $FX/askuser_selector.txt; else cat \"$PANE\"; fi ;;|" "$STUBBIN/tmux"
  grep -q 'askuser_selector' "$STUBBIN/tmux"
  send 4
  [ "$status" -ne 0 ]
  [[ "$output" == *"screen changed"* ]]
  no_keys_sent
}

# Refused by the one-digit rule, not merely because no "12." row is visible.
@test "permission: multi-digit is refused with the one-option-number message" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send 12
  [ "$status" -ne 0 ]
  [[ "$output" == *"one option number"* ]]
  no_keys_sent
}

# An option's wrapped continuation row can start with a number too ("1.2.3",
# "3.0/..."); only "N. " (number, dot, space) is an option row. Otherwise the
# wrap vouches for an option the dialog lacks, or hides the real ones above it.
@test "permission: a wrapped '3.0' continuation does not vouch for option 3 on a 2-option dialog" {
  printf '%s\n' ' Do you want to proceed?' ' ❯ 1. Yes, and always allow access to /opt/tool/v' \
    '      3.0/lib from this project' '   2. No' ' Esc to cancel · Tab to amend' > "$BATS_TEST_TMPDIR/wrap"
  stub_tmux "$BATS_TEST_TMPDIR/wrap"
  send 3
  [ "$status" -ne 0 ]
  no_keys_sent
}

@test "permission: a wrapped '1.2' continuation above the cursor does not hide option 2" {
  printf '%s\n' ' Do you want to proceed?' '   1. Yes' '   2. Yes, and always allow npm install pkg@' \
    '      1.2.3 from this project' ' ❯ 3. No' ' Esc to cancel · Tab to amend' > "$BATS_TEST_TMPDIR/wrap"
  stub_tmux "$BATS_TEST_TMPDIR/wrap"
  send 2
  [ "$status" -eq 0 ]
  grep -qx 'send-keys -t orch:w -l 2' "$CALLS"
}
