#!/usr/bin/env bats
# Hermetic tests for the send_prompt() buffer/Enter race fix (issue #14):
# unique tmux buffer names per send, and Enter gated on the paste buffer's
# deletion instead of a fixed sleep. tmux itself is stubbed so no real tmux
# server/session is needed and the tests run fully offline in CI.

# `run !` (used by the negative-assertion test below) is a 1.5.0+ feature.
bats_require_minimum_version 1.5.0

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

# Stubs `sleep` to record the literal argument send_prompt passes it (and to
# return instantly), so what the loop sleeps can be asserted as a value rather
# than inferred from wall clock -- deterministic, and free of the timing
# threshold that would otherwise have to be traded off against
# ORCH_TEST_TIMEOUT_SCALE on a loaded box (issue #125).
wire_sleep_recording_stub() { # <log path>
  : > "$1"
  cat > "$STUBBIN/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$1"
EOF
  chmod +x "$STUBBIN/sleep"
}

@test "send_prompt honours ORCH_SEND_POLL_INTERVAL as the poll-sleep bound" {
  # Prove the interval knob is actually plumbed into the loop's sleep, not
  # just accepted and ignored: a loop that kept a hardcoded 0.1 would record
  # "0.1" here instead of the injected "0.001".
  wire_always_present_buffer_stub
  sleep_calls="$BATS_TEST_TMPDIR/sleep_calls.log"
  wire_sleep_recording_stub "$sleep_calls"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  # `sleep` is stubbed to return instantly here, so a regression that lost the
  # poll-count cap would spin this loop hot forever and hang the whole bats run
  # rather than failing it. `timeout` is the hang detector, not slack.
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=20 ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 20 ]
  # 20 tries -> 19 sleeps between polls (none after the last, give-up, poll).
  sleep_line_count="$(wc -l < "$sleep_calls")"
  [ "$sleep_line_count" -eq 19 ]
  while IFS= read -r arg; do
    [ "$arg" = "0.001" ]
  done < "$sleep_calls"
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
  wire_sleep_recording_stub "$sleep_calls"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  # `unset` for the same reason the tries-default test unsets its knob: an
  # exported ORCH_SEND_POLL_INTERVAL in the developer's own shell would
  # otherwise be inherited here and quietly retarget the default this pins.
  run timeout "$(scaled_timeout 10)" bash -c "unset ORCH_SEND_POLL_INTERVAL; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 send_prompt orch:w1 hi"
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
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=abc send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='abc'" "$err_file"
}

@test "send_prompt rejects a numerically-zero ORCH_SEND_POLL_INTERVAL instead of busy-spinning" {
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=0.00 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='0.00'" "$err_file"
}

@test "send_prompt rejects a malformed-shape ORCH_SEND_POLL_INTERVAL (multiple dots)" {
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=1.2.3 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='1.2.3'" "$err_file"
}

@test "send_prompt rejects the leading-dot and trailing-dot ORCH_SEND_POLL_INTERVAL spellings" {
  # `sleep` itself accepts ".5", but the validator deliberately demands the
  # canonical "0.5" so the accepted shape stays narrow; a trailing dot ("5.")
  # is rejected for the same reason. Both must warn and fall back rather than
  # be silently accepted -- pinned here because only the comment described it.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  for bad in .5 5.; do
    err_file="$BATS_TEST_TMPDIR/stderr-$bad.log"
    run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL='$bad' send_prompt orch:w1 hi 2>'$err_file'"
    [ "$status" -eq 0 ]
    grep -q "invalid ORCH_SEND_POLL_INTERVAL='$bad'" "$err_file"
  done
}

@test "send_prompt ignores an inherited _ORCH_SEND_POLL_TRIES_DEFAULT" {
  # The fallback default is what the invalid-override path resets to and is
  # never itself re-validated, so it must not be environment-injectable: an
  # inherited `_ORCH_SEND_POLL_TRIES_DEFAULT=abc` used to survive into `tries`
  # and make `[ "$i" -ge abc ]` error on every iteration -- the cap never
  # fires and the send hangs unboundedly, exactly what the sanitising exists
  # to prevent. `timeout` here is the hang detector, not slack.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "export _ORCH_SEND_POLL_TRIES_DEFAULT=abc _ORCH_SEND_POLL_INTERVAL_DEFAULT=abc ORCH_SEND_POLL_TRIES=x; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q "using 50" "$err_file"
}

@test "send_prompt reports an explicitly-emptied ORCH_SEND_POLL_TRIES as invalid" {
  # `${VAR=...}` (no colon) at source time keeps an empty override empty so it
  # reaches the `''` case arm and is diagnosed, rather than being silently
  # swallowed into the default (issue #135 polish item 2).
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "export ORCH_SEND_POLL_TRIES=; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_INTERVAL=0.001 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 50 ]
  grep -q "invalid ORCH_SEND_POLL_TRIES=''" "$err_file"
}

@test "send_prompt rejects an ORCH_SEND_POLL_INTERVAL too large to stay bounded" {
  # Shape-valid but absurd: "999999999" passes the digits/dot/length checks yet
  # would sleep ~31 years per poll, so the poll-count cap never gets to fire and
  # the send hangs forever -- the exact failure the cap exists to prevent. The
  # whole-seconds part is therefore magnitude-capped as well as length-capped.
  wire_always_present_buffer_stub
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=999999999 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  polls="$(grep -c '^show-buffer' "$CALLS")"
  [ "$polls" -eq 3 ]
  grep -q "invalid ORCH_SEND_POLL_INTERVAL='999999999'" "$err_file"
}

@test "send_prompt accepts a multi-second ORCH_SEND_POLL_INTERVAL below the magnitude cap" {
  # The cap must not be so tight that ordinary slow-poll values are rejected:
  # a two-digit whole-seconds interval is still honoured verbatim.
  wire_always_present_buffer_stub
  sleep_calls="$BATS_TEST_TMPDIR/sleep_calls.log"
  wire_sleep_recording_stub "$sleep_calls"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 ORCH_SEND_POLL_INTERVAL=99 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  # `run !`, not a bare `!`: in Bats a bare `!` does not fail the test, so the
  # negative assertion would be decorative (shellcheck SC2314).
  run ! grep -q 'invalid ORCH_SEND_POLL_INTERVAL' "$err_file"
  [ "$(wc -l < "$sleep_calls")" -eq 2 ]
  while IFS= read -r arg; do
    [ "$arg" = "99" ]
  done < "$sleep_calls"
}

@test "send_prompt ignores an inherited _ORCH_SEND_POLL_INTERVAL_DEFAULT" {
  # Companion to the tries-default pin: the interval fallback is likewise never
  # re-validated, so an inherited `_ORCH_SEND_POLL_INTERVAL_DEFAULT=abc` would
  # be handed straight to `sleep`, which errors out instantly on every
  # iteration and turns the bounded poll loop into a busy spin. The recording
  # stub lets the *value slept* be asserted without paying 0.1s a poll.
  wire_always_present_buffer_stub
  sleep_calls="$BATS_TEST_TMPDIR/sleep_calls.log"
  wire_sleep_recording_stub "$sleep_calls"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"
  err_file="$BATS_TEST_TMPDIR/stderr.log"
  run timeout "$(scaled_timeout 10)" bash -c "export _ORCH_SEND_POLL_INTERVAL_DEFAULT=abc ORCH_SEND_POLL_INTERVAL=x; source '$BATS_TEST_DIRNAME/../_orch/lib.sh'; ORCH_SEND_POLL_TRIES=3 send_prompt orch:w1 hi 2>'$err_file'"
  [ "$status" -eq 0 ]
  grep -q "using 0.1" "$err_file"
  [ "$(wc -l < "$sleep_calls")" -eq 2 ]
  while IFS= read -r arg; do
    [ "$arg" = "0.1" ]
  done < "$sleep_calls"
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
