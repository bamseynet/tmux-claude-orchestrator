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

@test "permission: multi-digit 12 is refused" {
  stub_tmux "$FX/permission_dialog_4opt.txt"
  send 12
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
