#!/usr/bin/env bats
# Hermetic tests for _orch/send-remote-control.sh: types "/remote-control"
# into the orchestrator's own pane. tmux is fully stubbed (has-session,
# list-windows, display-message, capture-pane for pane_has_draft(),
# load/paste/show-buffer for send_prompt()) so no real tmux session or Claude
# loop is ever launched.

setup() {
  ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$ORCH_ROOT/_orch/lib.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/send-remote-control.sh" "$ORCH_ROOT/_orch/send-remote-control.sh"
  chmod +x "$ORCH_ROOT/_orch/send-remote-control.sh"

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
  list-sessions)
    echo "$SESSION"
    exit 0
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
  ( cd "$ORCH_ROOT" && unset ORCH_TARGET
    export SESSION_NAME="orch-testhash" ORCH_WINDOW="orchestrator"
    ./_orch/send-remote-control.sh "$@" )
}

@test "resolves the default target from SESSION_NAME:ORCH_WINDOW and sends the command" {
  run run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to orch-testhash:orchestrator"* ]]
  grep -q '^load-buffer' "$CALLS"
  grep -q '^paste-buffer.*-t orch-testhash:orchestrator' "$CALLS"
  grep -q '^send-keys -t orch-testhash:orchestrator Enter' "$CALLS"
}

@test "with SESSION_NAME unset, the default target is lib.sh's per-install hash, not the bare literal 'orch'" {
  # This is the regression the branch exists to prevent (issue #81): a
  # no-lib-sourced default of "orch" would silently target a stale/unrelated
  # session. Reconfigure the stub to accept ONLY the hash lib.sh itself would
  # derive for this ORCH_ROOT, and assert against it directly.
  expected_hash="$(bash -c '
    unset SESSION_NAME
    export ORCH_ROOT="'"$ORCH_ROOT"'"
    source "'"$ORCH_ROOT"'/_orch/lib.sh"
    printf %s "$SESSION_NAME"')"
  [[ "$expected_hash" =~ ^orch-[0-9a-f]{8}$ ]]
  [ "$expected_hash" != "orch" ]

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "$expected_hash" ] && exit 0; exit 1 ;;
  list-sessions) echo "$expected_hash" ;;
  list-windows) echo "$expected_hash:orchestrator" ;;
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

  run bash -c "cd '$ORCH_ROOT' && unset SESSION_NAME ORCH_WINDOW ORCH_TARGET; ./_orch/send-remote-control.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to $expected_hash:orchestrator"* ]]
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
  list-sessions) echo "other" ;;
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

@test "--force works after an explicit target argument too (order-independent)" {
  printf 'earlier output\n❯ half typed something' > "$PANE_TEXT_FILE"
  run run_script "orch-testhash:orchestrator" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control'"* ]]
  grep -q '^paste-buffer' "$CALLS"
}

@test "fails loudly (non-zero) on a session that does not exist" {
  run run_script "no-such-session:orchestrator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session"* ]]
}

@test "refuses to drive a DIFFERENT live session whose name is a prefix of the target (issue #96)" {
  # Real tmux's `has-session -t <name>` matches an unambiguous PREFIX, not just
  # an exact name (confirmed against tmux 3.4) -- fake that here so this stub
  # is never stricter than real tmux, same convention as
  # hygiene_session_namespace.bats / issue92_named_persistent_sessions.bats.
  # Only "billing" is actually live; "bill" is not. A bare
  # `tmux has-session -t bill` would still exit 0 (prefix match) and this
  # script would go on to drive billing's pane -- session_exists() must
  # refuse instead.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session)
    [ "\$3" = "billing" ] && exit 0
    [[ "billing" == "\$3"* ]] && exit 0
    exit 1
    ;;
  list-sessions) echo "billing" ;;
  list-windows) echo "billing:orchestrator" ;;
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

  run run_script "bill:orchestrator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux session: bill"* ]]
  ! grep -q '^paste-buffer' "$CALLS"
}

@test "fails loudly (non-zero) on a window that does not exist in a real session" {
  run run_script "orch-testhash:no-such-window"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux window"* ]]
}

@test "does not prefix-match the window part via a display-message fallback (issue #109)" {
  # Real tmux resolves the window part of a session:window target by
  # UNAMBIGUOUS PREFIX, same as the session part -- `tmux display-message -t
  # "$target"` would happily succeed for a target of "orchestrator" against a
  # real window named "orchestrator-extra". Model that here so a fallback
  # built on display-message cannot pass this test by accident. "orchestrator"
  # is not listed by `list-windows -F '#S:#W'` as an exact match (only
  # "orchestrator-extra" is), so the fix must not fall back to a prefix match.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "orch-testhash" ] && exit 0; exit 1 ;;
  list-sessions) echo "orch-testhash" ;;
  list-windows)
    if [ "\$5" = "#{window_index}" ]; then
      echo "0"
    else
      echo "orch-testhash:orchestrator-extra"
    fi
    ;;
  display-message)
    win="\${3#*:}"
    case "orchestrator-extra" in
      "\$win"*) exit 0 ;;
    esac
    exit 1
    ;;
  capture-pane) cat "$PANE_TEXT_FILE" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  run run_script "orch-testhash:orchestrator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux window"* ]]
  ! grep -q '^display-message' "$CALLS"
}

@test "an explicit window INDEX target (e.g. orch:0) still resolves" {
  # grep -qxF against '#S:#W' cannot express a bare numeric index like
  # "orch-testhash:1" (that format never appears in the #S:#W listing) -- the
  # index case must be handled explicitly, not via a prefix-matching fallback.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "orch-testhash" ] && exit 0; exit 1 ;;
  list-sessions) echo "orch-testhash" ;;
  list-windows)
    if [ "\$5" = "#{window_index}" ]; then
      printf '0\n1\n2\n'
    else
      echo "orch-testhash:orchestrator"
    fi
    ;;
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
  run run_script "orch-testhash:1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to orch-testhash:1"* ]]
}

@test "a zero-padded window INDEX target (e.g. orch:01) still resolves" {
  # Real tmux accepts zero-padded numeric window specs and resolves them the
  # same as their unpadded form (e.g. "orch:01" == "orch:1"), but
  # `tmux list-windows -F '#{window_index}'` always prints the unpadded form.
  # A literal grep -qxF of "01" against that unpadded listing would never
  # match -- the comparison must normalize the digit string first.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "orch-testhash" ] && exit 0; exit 1 ;;
  list-sessions) echo "orch-testhash" ;;
  list-windows)
    if [ "\$5" = "#{window_index}" ]; then
      printf '0\n1\n2\n'
    else
      echo "orch-testhash:orchestrator"
    fi
    ;;
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
  run run_script "orch-testhash:01"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sent '/remote-control' to orch-testhash:01"* ]]
}

@test "fails loudly when _orch/lib.sh is missing, instead of guessing a session name" {
  rm "$ORCH_ROOT/_orch/lib.sh"
  run run_script
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib.sh not found"* ]]
}

@test "rejects an unrecognized option instead of silently ignoring it" {
  run run_script --bogus-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "rejects a second positional argument instead of silently ignoring it" {
  run run_script "orch-testhash:orchestrator" "extra:arg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected extra argument"* ]]
}

@test "the window-existence check treats the target as a literal string, not a regex" {
  # A target containing a regex metacharacter ('.') must not match some OTHER
  # window via unintended regex semantics (grep -qxF, not -qx).
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  has-session) [ "\$3" = "orch-testhash" ] && exit 0; exit 1 ;;
  list-sessions) echo "orch-testhash" ;;
  list-windows) echo "orch-testhash:v1Xorchestrator" ;;   # NOT "v1.orchestrator"
  display-message) exit 1 ;;
  capture-pane) cat "$PANE_TEXT_FILE" ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  run run_script "orch-testhash:v1.orchestrator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tmux window"* ]]
}
