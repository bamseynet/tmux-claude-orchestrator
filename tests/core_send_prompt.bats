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
  # ORCH_SEND_POLL_TRIES is deliberately left unset -- that's the pin. The
  # interval IS overridden (tiny) so the 50-poll default is proven without
  # paying the real ~5s of 0.1s sleeps (issue #135); the interval's own
  # default is pinned separately below.
  run timeout "$(scaled_timeout 10)" bash -c "unset ORCH_SEND_POLL_TRIES; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi"
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
  # The fallback is the full 50-poll cap; with the interval also tiny that's
  # ~0.05s of sleeps rather than ~5s (issue #135), but keep the outer harness
  # timeout as slack regardless (issue #125).
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=abc ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi 2>'$err_file'"
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
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=99999999999999999999 ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi 2>'$err_file'"
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
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=00 ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q 'invalid ORCH_SEND_POLL_TRIES' "$err_file"
}

@test "send_prompt honours ORCH_SEND_POLL_INTERVAL as the poll-sleep bound" {
  # Prove the interval knob is actually plumbed into the loop's sleep, not
  # just accepted and ignored: 20 tries at a 0.001s interval is ~0.02s of
  # real sleeping; if the loop silently kept the 0.1s default instead, 19
  # inter-poll sleeps would take ~1.9s -- comfortably past the threshold, so
  # a hardcoded interval fails this test rather than slipping through on a
  # threshold too loose to notice the 100x difference.
  wire_always_present_buffer_stub
  start_ns="$(date +%s%N)"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=20 ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi"
  end_ns="$(date +%s%N)"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 20 ]
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  [ "$elapsed_ms" -lt 500 ]
}

@test "send_prompt pins the ORCH_SEND_POLL_INTERVAL default to 0.1 without paying real wall-clock cost" {
  # Cheap pin for the interval's own default (issue #135's "partial fix"
  # warning: a tiny interval in the other tests means they no longer pin the
  # 0.1 default). Rather than a real ~5s sleep-dominated test, stub `sleep`
  # itself to record the exact argument send_prompt passes it and return
  # instantly -- a timing *assertion* (what value is slept), not a timing
  # *measurement* (how long it took), so it is fast and deterministic.
  wire_always_present_buffer_stub
  sleep_calls="$BATS_TEST_TMPDIR/sleep_calls.log"
  : > "$sleep_calls"
  cat > "$STUBBIN/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$sleep_calls"
EOF
  chmod +x "$STUBBIN/sleep"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 send_prompt orch:w1 hi"
  [ "$status" -eq 0 ]
  # 3 tries -> 2 sleeps between polls (none after the last, give-up, poll).
  sleep_line_count="$(wc -l < "$sleep_calls")"
  [ "$sleep_line_count" -eq 2 ]
  while IFS= read -r arg; do
    [ "$arg" = "0.1" ]
  done < "$sleep_calls"
}

@test "send_prompt stays bounded when ORCH_SEND_POLL_INTERVAL is malformed" {
  wire_always_present_buffer_stub
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=abc send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='abc'" "$err_file"
}

@test "send_prompt rejects a numerically-zero ORCH_SEND_POLL_INTERVAL instead of busy-spinning" {
  wire_always_present_buffer_stub
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=0.00 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='0.00'" "$err_file"
}

@test "send_prompt rejects a malformed-shape ORCH_SEND_POLL_INTERVAL (multiple dots)" {
  wire_always_present_buffer_stub
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=1.2.3 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='1.2.3'" "$err_file"
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
