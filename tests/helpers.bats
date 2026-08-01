#!/usr/bin/env bats
# Hermetic test for a pure helper in _orch/lib.sh.
# lib.sh is meant to be sourced; its only load-time side effect is an idempotent
# `mkdir -p` under $ORCH_ROOT, which we redirect to a temp dir so the repo tree is
# never touched. strip_ansi shells out to perl (present on CI runners); no tmux/claude.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

@test "strip_ansi removes SGR colour escape sequences" {
  result="$(printf '\033[31mred\033[0m' | strip_ansi)"
  [ "$result" = "red" ]
}

@test "strip_ansi leaves plain text untouched" {
  result="$(printf 'plain text' | strip_ansi)"
  [ "$result" = "plain text" ]
}
