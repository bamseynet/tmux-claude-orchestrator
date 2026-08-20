#!/usr/bin/env bats
# Hermetic tests for send-remote-control.sh: types "/remote-control" into the
# orchestrator's own pane. tmux is fully stubbed (has-session, list-windows,
# display-message, capture-pane for pane_has_draft(), load/paste/show-buffer
# for send_prompt()) so no real tmux session or Claude loop is ever launched.

setup() {
  ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$ORCH_ROOT/_orch/lib.sh"
  cp "$BATS_TEST_DIRNAME/../send-remote-control.sh" "$ORCH_ROOT/send-remote-control.sh"
  chmod +x "$ORCH_ROOT/send-remote-control.sh"

  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  : > "$CALLS"
  printf 'noise\n❯ \n' > "$PANE_TEXT_FILE"   # idle prompt, no draft, by default

  # Session/window this "install" owns, so has-session/list-windows succeed.
  SESSION="orch-testhash"
  WINDOW="orchestrator"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session)
    [ "\$3" = "$SESSION" ] && exit 0
    exit 1
    ;;
  list-windows)
    echo "$SESSION:$WINDOW"
    exit 0
    ;;
  display-message)
    exit 1
    ;;
  capture-pane)
    cat "$PANE_TEXT_FILE"
    ;;
  load-buffer)
    name="\$3"
    cat > "\$bufdir/\$name"
    ;;
  paste-buffer)
    name=""
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-b" ]; then name="\$a"; fi
      prev="\$a"
    done
    rm -f "\$bufdir/\$name"
    ;;
  show-buffer)
    name="\$3"
    [ -f "\$bufdir/\$name" ] || exit 1
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"
}

run_script() {
  ( cd "$ORCH_ROOT" && unset SESSION_NAME ORCH_WINDOW TARGET
    export SESSION_NAME="orch-testhash" ORCH_WINDOW="orchestrator"
    ./send-remote-control.sh "$@" )
}

@test "resolves the default target from SESSION_NAME:ORCH_WINDOW and sends the command" {
  run run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to orch-testhash:orchestrator"* ]]
  grep -q '^load-buffer' "$CALLS"
  grep -q '^paste-buffer.*-t orch-testhash:orchestrator' "$CALLS"
  grep -q '^send-keys -t orch-testhash:orchestrator Enter' "$CALLS"
}

@test "an explicit target argument overrides the default" {
  # Reconfigure the stub session/window for the explicit target.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "other" ] && exit 0; exit 1 ;;
  list-windows) echo "other:otherwin" ;;
  display-message) exit 1 ;;
  capture-pane) cat "$PANE_TEXT_FILE" ;;
  load-buffer) name="\$3"; cat > "\$bufdir/\$name" ;;
  paste-buffer)
    name=""; prev=""
    for a in "\$@"; do [ "\$prev" = "-b" ] && name="\$a"; prev="\$a"; done
    rm -f "\$bufdir/\$name" ;;
  show-buffer) name="\$3"; [ -f "\$bufdir/\$name" ] || exit 1; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"

  run run_script "other:otherwin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to other:otherwin"* ]]
}

@test "skips sending when the pane holds an unsent draft" {
  printf 'earlier output\n❯ half typed something' > "$PANE_TEXT_FILE"
  run run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsent draft"* ]]
  ! grep -q '^paste-buffer' "$CALLS"
}

@test "--force overrides the draft guard" {
  printf 'earlier output\n❯ half typed something' > "$PANE_TEXT_FILE"
  run run_script --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control'"* ]]
  grep -q '^paste-buffer' "$CALLS"
}

@test "fails loudly (non-zero) on a session that does not exist" {
  run run_script "no-such-session:orchestrator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session"* ]]
}

@test "fails loudly (non-zero) on a window that does not exist in a real session" {
  run run_script "orch-testhash:no-such-window"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux window"* ]]
}

@test "fails loudly when _orch/lib.sh is missing, instead of guessing a session name" {
  rm "$ORCH_ROOT/_orch/lib.sh"
  run run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib.sh not found"* ]]
}
