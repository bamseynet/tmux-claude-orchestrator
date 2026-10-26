#!/usr/bin/env bats
# Issue #155: TUI state detectors keyed on one glyph ("❯") were fooled by dialogs.
# Matrix of (screen x detector), plus call-site proof for send.sh / ask.sh.
#
# Fixture provenance: `trust` is a real capture (Claude Code 2.1.310, quoted in
# issue #179 from a throwaway-socket launch in a fresh dir). `perm` is NOT a real
# capture: the `❯ 1. Yes` row is our ASSUMPTION about the real render (PR #154's
# fixture omitted it); no real permission dialog was captured (#179 A2 / part B).
# banner/chip/busy/idle are shapes already used by injectfix_* / panestate_* tests.

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

  SCREEN_banner='✻ Welcome to Claude Code!

╭──────────────╮
│ ❯            │
╰──────────────╯
  ? for shortcuts'
  # Real capture, Claude Code 2.1.310, captured 2026-10-26 (quoted in issue #179;
  # the issue elides the scratch path, so that one line is ours). Note the leading space before ❯.
  SCREEN_trust=' Accessing workspace:
 /tmp/scratch/fresh179-18039
 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
 project, or work from your team). If not, take a moment to review what'"'"'s in this folder first.
 Claude Code'"'"'ll be able to read, edit, and execute files here.
 Security guide
 ❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel'
  SCREEN_perm=' Bash command
   rm -rf build
 Do you want to proceed?
❯ 1. Yes
  2. No'
  SCREEN_chip='╭──────────────╮
│ ❯ [Pasted text #1 +5 lines] │
╰──────────────╯
  ? for shortcuts'
  SCREEN_busy='✻ Thinking… (esc to interrupt)
╭──────────────╮
│ ❯            │
╰──────────────╯'
  SCREEN_idle='● done
╭──────────────╮
│ ❯            │
╰──────────────╯
  ? for shortcuts'
}

# cell <screen> <detector> <Y|n>
cell() {
  local screen="$1" fn="$2" want="$3" var="SCREEN_$1" got
  fake_tmux_set_pane "orch" "w" "${!var}"
  if "$fn" "$T"; then got=Y; else got=n; fi
  [ "$got" = "$want" ] || { echo "$fn on $screen: want $want got $got"; return 1; }
}

@test "is_ready: banner Y"     { cell banner is_ready Y; }
@test "is_ready: trust n"      { cell trust  is_ready n; }
@test "is_ready: perm n"       { cell perm   is_ready n; }
@test "is_ready: chip Y"       { cell chip   is_ready Y; }
@test "is_ready: busy n"       { cell busy   is_ready n; }
@test "is_ready: idle Y"       { cell idle   is_ready Y; }

@test "pane_active: banner Y"  { cell banner pane_active Y; }
@test "pane_active: trust n"   { cell trust  pane_active n; }
@test "pane_active: perm n"    { cell perm   pane_active n; }
@test "pane_active: chip n"    { cell chip   pane_active n; }
@test "pane_active: busy Y"    { cell busy   pane_active Y; }
@test "pane_active: idle n"    { cell idle   pane_active n; }

@test "inject_confirmed: banner n" { cell banner inject_confirmed n; }
@test "inject_confirmed: trust n"  { cell trust  inject_confirmed n; }
@test "inject_confirmed: perm Y"   { cell perm   inject_confirmed Y; }
@test "inject_confirmed: chip n"   { cell chip   inject_confirmed n; }
@test "inject_confirmed: busy Y"   { cell busy   inject_confirmed Y; }
@test "inject_confirmed: idle Y"   { cell idle   inject_confirmed Y; }

# --- call sites: real scripts against a stub tmux -------------------------------

stub_tmux() { # <screen>
  local var="SCREEN_$1"
  STUBBIN="$BATS_TEST_TMPDIR/bin"; CALLS="$BATS_TEST_TMPDIR/calls"; PANE="$BATS_TEST_TMPDIR/pane"
  mkdir -p "$STUBBIN"; : > "$CALLS"; printf '%s\n' "${!var}" > "$PANE"
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows) printf '%s\n' orchestrator w ;;
  capture-pane)
    # optional screen switch after N captures (a dialog rendering mid-wait)
    if [ -f "$PANE.next" ]; then
      n=\$(( \$(cat "$PANE.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$PANE.count"
      [ "\$n" -lt "\$(cat "$PANE.after")" ] || mv "$PANE.next" "$PANE"
    fi
    cat "$PANE" ;;
  paste-buffer) [ -f "$PANE.onpaste" ] && mv "$PANE.onpaste" "$PANE" ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/tmux"
  export PATH="$STUBBIN:$PATH" SESSION_NAME=orch
}

no_keys_sent() { ! grep -qE 'send-keys|paste-buffer|load-buffer' "$CALLS"; }

@test "send.sh refuses to paste into the trust dialog" {
  stub_tmux trust
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"dialog"* ]]
  no_keys_sent
}

@test "send.sh refuses to paste into the permission dialog" {
  stub_tmux perm
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"dialog"* ]]
  no_keys_sent
}

@test "send.sh still delivers a dialog answer (orch send 1)" {
  stub_tmux perm
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w 1
  [ "$status" -eq 0 ]
  grep -q 'paste-buffer' "$CALLS"
}

@test "ask.sh refuses to paste into a dialog" {
  stub_tmux trust
  run bash "$BATS_TEST_DIRNAME/../_orch/ask.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"dialog"* ]]
  no_keys_sent
}

# switch_after <n> <screen>: the stub pane shows <screen> from capture <n> on.
switch_after() { local var="SCREEN_$2"; echo "$1" > "$PANE.after"; printf '%s\n' "${!var}" > "$PANE.next"; }

@test "send.sh refuses a dialog that renders while it waits for ready" {
  stub_tmux busy
  switch_after 4 perm
  SECONDS=0
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"dialog"* ]]
  [ ! -f "$PANE.next" ]   # the switch really happened mid-wait
  [ "$SECONDS" -lt 15 ]   # and ended the 30s wait early
  no_keys_sent
}

@test "send.sh refuses a dialog that renders during the post-ready settle" {
  stub_tmux idle
  # captures 1-4 are the poll that finds the pane ready; 5 is the re-check
  # after the settle sleep
  switch_after 5 perm
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"dialog"* ]]
  [ ! -f "$PANE.next" ]
  no_keys_sent
}

@test "ask.sh returns at once when the answer stops on a dialog" {
  stub_tmux idle
  local var="SCREEN_perm"; printf '%s\n' "${!var}" > "$PANE.onpaste"
  SECONDS=0
  ORCH_ASK_TIMEOUT=30 run bash "$BATS_TEST_DIRNAME/../_orch/ask.sh" w hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"showing a dialog"* ]]
  [ "$SECONDS" -lt 15 ]
}

@test "wait_ready_or_dialog: 2 on a dialog, 0 when ready, 1 on timeout" {
  local rc
  fake_tmux_set_pane "orch" "w" "$SCREEN_trust"
  rc=0; wait_ready_or_dialog "$T" 0 || rc=$?; [ "$rc" -eq 2 ]
  fake_tmux_set_pane "orch" "w" "$SCREEN_idle"
  rc=0; wait_ready_or_dialog "$T" 0 || rc=$?; [ "$rc" -eq 0 ]
  fake_tmux_set_pane "orch" "w" "$SCREEN_busy"
  rc=0; wait_ready_or_dialog "$T" 0 || rc=$?; [ "$rc" -eq 1 ]
}

@test "send.sh still sends to an ordinary ready pane" {
  stub_tmux idle
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -eq 0 ]
  grep -q 'paste-buffer' "$CALLS"
}

# --- #179 A: an unsent paste chip is not a dialog, but pasting + Enter onto it
# would submit the stuck chip together with the new text. The veto lives in
# send.sh/ask.sh (pane_has_pending_paste), NOT in is_ready, so spawn's send_task
# and the heartbeat is_ready checks keep their behaviour; hence `is_ready: chip Y`.

@test "send.sh refuses to paste onto an unsent paste chip" {
  stub_tmux chip
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsent paste"* ]]
  no_keys_sent
}

@test "ask.sh refuses to paste onto an unsent paste chip" {
  stub_tmux chip
  run bash "$BATS_TEST_DIRNAME/../_orch/ask.sh" w hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsent paste"* ]]
  no_keys_sent
}

@test "send.sh still sends when a chip is only in scrollback, not the input row" {
  SCREEN_echo='❯ [Pasted text #1 +5 lines]
● done
╭──────────────╮
│ ❯            │
╰──────────────╯
  ? for shortcuts'
  stub_tmux echo
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w hi
  [ "$status" -eq 0 ]
  grep -q 'paste-buffer' "$CALLS"
}

@test "send.sh still answers a dialog (orch send 1) with a chip echoed above it" {
  # Real dialogs highlight a choice row with the glyph (see the 2.1.310 trust
  # capture), so that row, not the chip echo above it, is the last glyph row.
  # A glyph-less choice row would make send.sh refuse: fail-safe, not a submit.
  SCREEN_dlgchip="❯ [Pasted text #1 +5 lines]
$SCREEN_trust"
  # Precondition: this must take the wr=2 (dialog) path, not a 30s timeout.
  fake_tmux_set_pane "orch" "w" "$SCREEN_dlgchip"; pane_has_dialog "$T"
  stub_tmux dlgchip
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w 1
  [ "$status" -eq 0 ]
  grep -q 'paste-buffer' "$CALLS"
}

@test "send.sh refuses a numeric send when the live chip sits BELOW stale dialog text" {
  # Dialog-shaped text in the transcript makes wait_ready_or_dialog return 2,
  # but the real input box (with the stuck chip) is drawn below it: a real
  # dialog hides the input box, so Enter here would submit the chip + "1".
  SCREEN_stalechip=' Do you want to proceed?
 1. Yes
  2. No
● done
╭──────────────╮
│ ❯ [Pasted text #1 +5 lines] │
╰──────────────╯
  ? for shortcuts'
  # Precondition: the stale text really is dialog-shaped, so the numeric send
  # passes the dialog gate and only the chip veto can stop it.
  fake_tmux_set_pane "orch" "w" "$SCREEN_stalechip"; pane_has_dialog "$T"
  stub_tmux stalechip
  run bash "$BATS_TEST_DIRNAME/../_orch/send.sh" w 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsent paste"* ]]
  no_keys_sent
}
