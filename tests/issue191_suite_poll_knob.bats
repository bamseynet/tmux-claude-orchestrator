#!/usr/bin/env bats
# #191: tests/setup_suite.bash caps send_prompt's paste-buffer poll for the
# whole suite, because ~51 inline tmux stubs answer `show-buffer` with success
# forever and every stubbed spawn.sh otherwise burns the 50x0.1s cap (~5.5s).

# Run a one-test nested suite that carries a copy of setup_suite.bash and
# reports ORCH_SEND_POLL_TRIES as seen from a `run bash -c` child. The probe is
# built with printf: a heredoc line starting with `@test` would be rewritten by
# this file's own bats preprocessor.
nested_probe() {
  local d="$BATS_TEST_TMPDIR/nested"
  mkdir -p "$d"
  cp "$BATS_TEST_DIRNAME/setup_suite.bash" "$d/setup_suite.bash"
  printf '%s\n' \
    '@test "probe" {' \
    '  run bash -c '"'"'printf %s "${ORCH_SEND_POLL_TRIES-unset}"'"'"'' \
    '  echo "TRIES=$output" >&3' \
    '}' >"$d/probe.bats"
  # A nested bats must not inherit the outer run's BATS_* bookkeeping.
  local -a scrub=() v
  for v in $(compgen -e | grep '^BATS_'); do scrub+=(-u "$v"); done
  run env "${scrub[@]}" "$@" bats "$d/probe.bats" 3>&1
}

@test "suite default: ORCH_SEND_POLL_TRIES is 1 when the caller did not set it" {
  nested_probe -u ORCH_SEND_POLL_TRIES
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIES=1"* ]]
}

@test "setup_suite keeps a caller's ORCH_SEND_POLL_TRIES (uses :-, no clobber)" {
  nested_probe ORCH_SEND_POLL_TRIES=7
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIES=7"* ]]
}

@test "runtime default stays 50 (setup_suite must not touch _orch/)" {
  run grep -n '^_ORCH_SEND_POLL_TRIES_DEFAULT=50$' "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  [ "$status" -eq 0 ]
}
