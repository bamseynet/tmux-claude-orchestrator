#!/usr/bin/env bats
# #191: tests/setup_suite.bash caps send_prompt's paste-buffer poll for the
# whole suite, because ~51 inline tmux stubs answer `show-buffer` with success
# forever and every stubbed spawn.sh otherwise burns the 50x0.1s cap (~5.5s).

# What a `run bash -c` child sees after setup_suite ran with the given caller
# env (leading args are `env` operands, e.g. -u VAR or VAR=val).
poll_tries_after_setup_suite() {
  run env "$@" bash -c 'source "$1"; setup_suite; printf %s "${ORCH_SEND_POLL_TRIES-unset}"' _ "$BATS_TEST_DIRNAME/setup_suite.bash"
}

@test "setup_suite defaults ORCH_SEND_POLL_TRIES to 1 when the caller did not set it" {
  poll_tries_after_setup_suite -u ORCH_SEND_POLL_TRIES
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "setup_suite keeps a caller's ORCH_SEND_POLL_TRIES (uses :-, no clobber)" {
  poll_tries_after_setup_suite ORCH_SEND_POLL_TRIES=7
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "setup_suite is actually loaded: the knob is set inside the suite" {
  [ -n "${ORCH_SEND_POLL_TRIES-}" ]
}

@test "runtime default stays 50 (setup_suite must not touch _orch/)" {
  run grep -n '^_ORCH_SEND_POLL_TRIES_DEFAULT=50$' "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  [ "$status" -eq 0 ]
}
