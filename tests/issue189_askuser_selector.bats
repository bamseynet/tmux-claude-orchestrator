#!/usr/bin/env bats
# Issue #189: an open AskUserQuestion selector was not a "dialog", so the
# heartbeat's #52 draft valve (and send/ask/watchdog) typed Enter into it and
# auto-picked option 1.
#
# Fixture provenance: tests/fixtures/askuser_selector.txt is a REAL capture,
# Claude Code 2.1.310 (haiku), 120x40, throwaway `tmux -L` socket in a scratch
# dir, captured 2026-10-26 (`capture-pane -p`, trailing blank rows trimmed).
# The cursor-on-option-2 and multi-question variants are derived from it with
# sed and are ASSUMED shapes (not separately captured).

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
  FIX="$BATS_TEST_DIRNAME/fixtures/askuser_selector.txt"
  SCREEN_ask="$(cat "$FIX")"
  SCREEN_ask2="$(sed -e 's/^❯ 1\./  1./' -e 's/^  2\. Merge now/❯ 2. Merge now/' "$FIX")"
  SCREEN_askmulti="$(sed 's/^ ☐ PR 165/ ☐ PR 165  ☐ Scope  ✔ Submit/' "$FIX")"
  # Real capture, same session: the footerless review screen a multi-question
  # selector ends on; Enter there submits every answer.
  SCREEN_review="$(cat "$BATS_TEST_DIRNAME/fixtures/askuser_review.txt")"
  SCREEN_prose='● Options:
1. Keep looping
2. Merge now
3. Close it
╭──────────────╮
│ >            │
╰──────────────╯
  ? for shortcuts'
  SCREEN_idle='● done
╭──────────────╮
│ ❯            │
╰──────────────╯
  ? for shortcuts'
}

cell() { # <screen> <detector> <Y|n>
  local var="SCREEN_$1" got
  fake_tmux_set_pane "orch" "w" "${!var}"
  if "$2" "$T"; then got=Y; else got=n; fi
  [ "$got" = "$3" ] || { echo "$2 on $1: want $3 got $got"; return 1; }
}

@test "pane_has_dialog: real AskUserQuestion selector Y"   { cell ask       pane_has_dialog Y; }
@test "pane_has_dialog: cursor on option 2 Y"              { cell ask2      pane_has_dialog Y; }
@test "pane_has_dialog: multi-question header Y"           { cell askmulti  pane_has_dialog Y; }
@test "pane_has_dialog: multi-question review screen Y"    { cell review    pane_has_dialog Y; }
@test "is_ready refuses the review screen"                 { cell review    is_ready n; }
@test "pane_has_dialog: numbered prose above idle box n"   { cell prose     pane_has_dialog n; }
@test "pane_has_dialog: idle prompt n"                     { cell idle      pane_has_dialog n; }
@test "is_ready refuses the selector"                      { cell ask       is_ready n; }
@test "inject_confirmed: selector is positive evidence"    { cell ask       inject_confirmed Y; }
@test "inject_confirmed: selector beats a visible banner" {
  fake_tmux_set_pane "orch" "w" "✻ Welcome to Claude Code!
$SCREEN_ask"
  inject_confirmed "$T"
}

# --- call sites ------------------------------------------------------------------

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

@test "send.sh refuses non-numeric text onto the selector" {
  stub_tmux "$FIX"
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"showing a question selector"* ]]
  ! grep -qE 'send-keys|paste-buffer|load-buffer' "$CALLS"
}

# Live-checked on 2.1.310: a PASTED digit is ignored by the selector and the
# paste's Enter answers with the highlighted option (send 2 -> got option 1); a
# TYPED digit selects on its own. So: one literal key, no paste, no Enter.
@test "send.sh answers the selector by typing the digit, without paste or Enter" {
  stub_tmux "$FIX"
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w 2
  [ "$status" -eq 0 ]
  grep -qx 'send-keys -t orch:w -l 2' "$CALLS"
  ! grep -qE 'paste-buffer|load-buffer|Enter' "$CALLS"
}

# Live-checked: typing the "Type something." number moves the cursor onto a
# text row (footer gains "ctrl+g to edit in Vim"); paste + Enter there submits
# the text as the answer.
@test "send.sh pastes free text (with Enter) once the cursor is on Type something" {
  stub_tmux "$BATS_TEST_DIRNAME/fixtures/askuser_text_entry.txt"
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w "blue fish"
  [ "$status" -eq 0 ]
  [[ "$output" == *"free-text answer"* ]]
  grep -q 'paste-buffer' "$CALLS"
  grep -qx 'send-keys -t orch:w Enter' "$CALLS"
}

@test "send.sh refuses a multi-digit answer on the selector (would answer the next question)" {
  stub_tmux "$FIX"
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w 12
  [ "$status" -ne 0 ]
  [[ "$output" == *"one option number"* ]]
  ! grep -qE 'send-keys|paste-buffer|load-buffer' "$CALLS"
}

# Real tmux emits every pane row: in a fresh, taller-than-content pane the rows
# below the selector are blank, and a plain `tail -n 25` dropped the cursor row.
@test "pane_has_dialog: selector at the top of a 40-row pane (trailing blank rows) Y" {
  stub_tmux "$FIX"
  for _ in $(seq 16); do echo; done >> "$PANE"
  unset -f tmux
  pane_has_dialog "$T"
}

@test "spawn ladder fallback: selector counts as post-acceptance evidence" {
  cell ask pane_has_postaccept_dialog Y
}
