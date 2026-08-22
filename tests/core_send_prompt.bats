#!/usr/bin/env bats
# Hermetic tests for the send_prompt() buffer/Enter race fix (issue #14):
# unique tmux buffer names per send, and Enter gated on the paste buffer's
# deletion instead of a fixed sleep. tmux itself is stubbed so no real tmux
# server/session is needed and the tests run fully offline in CI.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"

  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"

  # tmux stub: records every invocation; load-buffer/paste-buffer/show-buffer
  # are backed by a real flat file per buffer name so -d ("delete after paste")
  # and show-buffer's "not found" behaviour are faithfully reproduced.
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
bufdir="$BATS_TEST_TMPDIR/bufs"
mkdir -p "\$bufdir"
case "\$1" in
  load-buffer)
    # form: load-buffer -b <name> -   (reads stdin)
    name="\$3"
    cat > "\$bufdir/\$name"
    ;;
  paste-buffer)
    # form: paste-buffer -p -d -b <name> -t <target>
    name=""
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-b" ]; then name="\$a"; fi
      prev="\$a"
    done
    rm -f "\$bufdir/\$name"   # -d: delete after pasting
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

@test "send_prompt uses a distinct buffer name on each call to the same target" {
  send_prompt "orch:w1" "first message"
  send_prompt "orch:w1" "second message"
  buf1="$(grep -o 'load-buffer -b [^ ]*' "$CALLS" | sed -n '1p' | awk '{print $3}')"
  buf2="$(grep -o 'load-buffer -b [^ ]*' "$CALLS" | sed -n '2p' | awk '{print $3}')"
  [ -n "$buf1" ]
  [ -n "$buf2" ]
  [ "$buf1" != "$buf2" ]
}

@test "send_prompt loads, pastes and deletes the buffer, then sends Enter, in order" {
  send_prompt "orch:w1" "hello"
  grep -q '^load-buffer' "$CALLS"
  grep -q '^paste-buffer.*-d.*-t orch:w1' "$CALLS"
  grep -q '^send-keys -t orch:w1 Enter' "$CALLS"
  # Enter must come after the paste, not before.
  paste_line="$(grep -n '^paste-buffer' "$CALLS" | head -1 | cut -d: -f1)"
  enter_line="$(grep -n '^send-keys -t orch:w1 Enter' "$CALLS" | head -1 | cut -d: -f1)"
  [ "$paste_line" -lt "$enter_line" ]
}

@test "send_prompt gates Enter on the buffer actually being gone (show-buffer polled)" {
  send_prompt "orch:w1" "hello"
  grep -q '^show-buffer' "$CALLS"
}

wire_always_present_buffer_stub() {
  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
  show-buffer) exit 0 ;;   # always "still there"
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
}

@test "send_prompt honours ORCH_SEND_POLL_TRIES as the poll-count bound, fast" {
  # Stub a tmux where show-buffer always reports the buffer present, to prove
  # the poll loop is bounded by the injectable knob rather than a fixed 50.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 send_prompt orch:w1 hi"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  enters="$(grep -c '^send-keys -t orch:w1 Enter' "$CALLS")"
  [ "$enters" -eq 1 ]
  last_poll_line="$(grep -n '^show-buffer' "$CALLS" | tail -1 | cut -d: -f1)"
  enter_line="$(grep -n '^send-keys -t orch:w1 Enter' "$CALLS" | head -1 | cut -d: -f1)"
  [ "$last_poll_line" -lt "$enter_line" ]
}

@test "send_prompt defaults ORCH_SEND_POLL_TRIES to 50 when unset" {
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  run timeout "$(scaled_timeout 10)" bash -c "unset ORCH_SEND_POLL_TRIES; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; send_prompt orch:w1 hi"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
}

@test "send_prompt logs a diagnostic on give-up and still sends Enter" {
  wire_always_present_buffer_stub
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=2 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  grep -q 'send_prompt:' "$err_file"
  grep -q 'ungated' "$err_file"
  enters="$(grep -c '^send-keys -t orch:w1 Enter' "$CALLS")"
  [ "$enters" -eq 1 ]
}

@test "send_prompt stays bounded when ORCH_SEND_POLL_TRIES is malformed" {
  # A non-numeric (or zero) override must not defeat the cap: the `-ge` test
  # would error on every iteration and the loop would spin forever, which is
  # the exact hang the cap exists to prevent.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  # The fallback is the full 50-poll cap (~5s of sleeps), so give the outer
  # harness timeout plenty of slack on a loaded box (issue #125).
  run timeout "$(scaled_timeout 30)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=abc send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q 'invalid ORCH_SEND_POLL_TRIES' "$err_file"
  enters="$(grep -c '^send-keys -t orch:w1 Enter' "$CALLS")"
  [ "$enters" -eq 1 ]
}

@test "send_prompt stays bounded when ORCH_SEND_POLL_TRIES is all digits but unusable" {
  # An all-digit value that `[ -ge ]` cannot parse as an integer (wider than
  # intmax) errors on every iteration, so the cap would never fire — the same
  # unbounded hang as a non-numeric value. Leading-zero values ("00") are the
  # mirror image: they compare as 0 and give up on the very first poll.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 30)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=99999999999999999999 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q 'invalid ORCH_SEND_POLL_TRIES' "$err_file"
}

@test "send_prompt rejects a leading-zero ORCH_SEND_POLL_TRIES instead of giving up at once" {
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 30)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=00 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q 'invalid ORCH_SEND_POLL_TRIES' "$err_file"
}

@test "send_prompt stays silent on the normal path where the buffer clears" {
  # Default setup() stub: paste-buffer really deletes the buffer file, so
  # show-buffer reports it gone well before the poll cap.
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  [ ! -s "$err_file" ]
}

@test "lib.sh derives the send_prompt buffer name from pid/RANDOM/call-count, not target alone" {
  grep -Fq '_SEND_PROMPT_SEQ' "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  grep -Eq 'buf="b-\$\{target//\[\^a-zA-Z0-9\]/_\}-\$\$-\$\{RANDOM\}' "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}
