#!/usr/bin/env bats
# Issue #196: `orch send <id> 3` on a file edit/create/overwrite or WebFetch
# permission dialog approved it (Enter took "1. Yes"): permission_dialog_regex
# only knew "Do you want to proceed?".
#
# Fixture provenance (Claude Code 2.1.310, throwaway `tmux -L` socket, quoted in
# issue #196): permission_edit.txt and permission_create.txt are REAL captures
# (blank lines dropped, ╌ shortened). permission_overwrite.txt, permission_webfetch.txt
# and permission_edit_wrapped.txt are RECONSTRUCTED from the issue's table of
# verified headers/options (body lines are ours; the wrapped form follows the
# notebook capture's "(shift+tab)" wrap). prose_*.txt are SYNTHETIC negatives.

setup() {
  export FAKE_TMUX_STATE="$BATS_TEST_TMPDIR/fake-tmux-state"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/fake-tmux.bash"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  fake_tmux_add_session "orch" "w"
  T="orch:w"
  FX="$BATS_TEST_DIRNAME/fixtures"
}

FILE_DIALOGS="permission_edit permission_create permission_overwrite permission_webfetch permission_edit_wrapped"

@test "pane_has_permission_dialog is true on every file/fetch dialog fixture" {
  for f in $FILE_DIALOGS; do
    fake_tmux_set_pane orch w "$(cat "$FX/$f.txt")"
    pane_has_permission_dialog "$T" || { echo "missed: $f"; return 1; }
  done
}

@test "trust and askuser detectors are false on every file/fetch dialog fixture" {
  for f in $FILE_DIALOGS; do
    fake_tmux_set_pane orch w "$(cat "$FX/$f.txt")"
    ! pane_has_trust_dialog "$T" || { echo "trust fired: $f"; return 1; }
    ! pane_has_askuser_dialog "$T" || { echo "askuser fired: $f"; return 1; }
  done
}

@test "negative: 'Do you want to ...?' prose with no 1. Yes row is not a dialog" {
  fake_tmux_set_pane orch w "$(cat "$FX/prose_no_choice.txt")"
  ! pane_has_permission_dialog "$T"
}

@test "negative: indented prose + numbered list without the cursor is not a dialog" {
  fake_tmux_set_pane orch w "$(cat "$FX/prose_list_no_cursor.txt")"
  ! pane_has_permission_dialog "$T"
}

@test "regression: the Do you want to proceed? fixtures still match" {
  for f in permission_dialog_2opt permission_dialog_4opt; do
    fake_tmux_set_pane orch w "$(cat "$FX/$f.txt")"
    pane_has_permission_dialog "$T" || { echo "missed: $f"; return 1; }
  done
}

@test "the lib.sh fallback default recognises the file dialogs (config absent)" {
  rm -f "$ORCH_ROOT/_orch/config.json"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; printf '%s\n' ' Do you want to create x?' ' ❯ 1. Yes' | grep -qE \"\$TUI_PERMISSION_DIALOG_REGEX\" && printf '%s\n' ' ❯ 1. Yes' | grep -qE \"\$TUI_PERMISSION_CHOICE_REGEX\""
  [ "$status" -eq 0 ]
}

# --- send.sh against a stub tmux -------------------------------------------------

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

@test "send 3 on each file/fetch dialog types a literal 3: no paste, no Enter" {
  for f in $FILE_DIALOGS; do
    stub_tmux "$FX/$f.txt"
    send 3
    [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
    grep -qx 'send-keys -t orch:w -l 3' "$CALLS" || { echo "no -l 3: $f"; return 1; }
    ! grep -qE 'paste-buffer|load-buffer|Enter' "$CALLS" || { echo "paste/Enter: $f"; return 1; }
  done
}

@test "free text on each file/fetch dialog is refused, nothing sent" {
  for f in $FILE_DIALOGS; do
    stub_tmux "$FX/$f.txt"
    send hello
    [ "$status" -ne 0 ]
    no_keys_sent || { echo "keys sent: $f"; return 1; }
  done
}

@test "send 4 on a 3-option file dialog is refused" {
  stub_tmux "$FX/permission_edit.txt"
  send 4
  [ "$status" -ne 0 ]
  no_keys_sent
}

# Spawn/inject callers treat the dialog as "don't paste": proof for inject_confirmed.
@test "inject_confirmed treats a file dialog as landed (dialog up, not blank)" {
  fake_tmux_set_pane orch w "$(cat "$FX/permission_create.txt")"
  inject_confirmed "$T"
}

# --- review pass 1: cursor off row 1, wrapped header, parity -------------------

@test "cursor on option 2 or 3 is still a dialog; send refuses free text, types digits" {
  for row in 2 3; do
    sed -e 's/^ ❯ 1\./   1./' -e "s/^   $row\./ ❯ $row./" "$FX/permission_edit.txt" > "$BATS_TEST_TMPDIR/moved"
    grep -q "^ ❯ $row\." "$BATS_TEST_TMPDIR/moved"
    fake_tmux_set_pane orch w "$(cat "$BATS_TEST_TMPDIR/moved")"
    pane_has_permission_dialog "$T" || { echo "missed cursor row $row"; return 1; }
    stub_tmux "$BATS_TEST_TMPDIR/moved"
    send hello
    [ "$status" -ne 0 ]
    no_keys_sent
  done
}

@test "a header wrapped across lines (no closing ? on its first line) is still a dialog" {
  printf '%s\n' ' Do you want to make this edit to /very/long/path/that/wraps/' ' beyond/the/pane/width.txt?' \
    ' ❯ 1. Yes' '   2. Yes, and switch to accept edits' '   3. No' ' Esc to cancel' > "$BATS_TEST_TMPDIR/wraphdr"
  fake_tmux_set_pane orch w "$(cat "$BATS_TEST_TMPDIR/wraphdr")"
  pane_has_permission_dialog "$T"
  stub_tmux "$BATS_TEST_TMPDIR/wraphdr"
  send 3
  grep -qx 'send-keys -t orch:w -l 3' "$CALLS"
  ! grep -qE 'paste-buffer|load-buffer|Enter' "$CALLS"
}

@test "negative: 'Do you want to keep going? ...' mid-line prose with a cursor row is not a dialog" {
  fake_tmux_set_pane orch w ' Do you want to keep going? Maybe.
 ❯ 1. Yes
   2. No'
  ! pane_has_permission_dialog "$T"
}

@test "the lib.sh fallback regexes equal the shipped _orch/config.json values" {
  for k in permission_dialog_regex permission_dialog_choice_regex; do
    want="$(jq -r ".tui_patterns.$k" "$BATS_TEST_DIRNAME/../_orch/config.json")"
    grep -qF -- "_tui_pattern $k '$want')" "$BATS_TEST_DIRNAME/../_orch/lib.sh" || { echo "drift: $k"; return 1; }
  done
}
