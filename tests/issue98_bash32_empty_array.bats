#!/usr/bin/env bats
# Regression test for issue #98: `./orch up --name test` (and bare `./orch up`)
# died with `_orch/bootstrap.sh: line 80: bootstrap_args[@]: unbound variable`.
#
# The mechanism: `set -- "${bootstrap_args[@]}"` expands an EMPTY array under
# `set -u`. bash < 4.4 treats that as an unbound-variable error; bash >= 4.4
# does not. This box and CI (ubuntu-latest) both run bash >= 4.4, but macOS
# ships bash 3.2 as /bin/bash -- which is how this shipped in #93 and broke in
# production minutes later despite three review rounds and a 511-test suite.
#
# A test that merely runs bootstrap.sh's parsing under the HOST bash proves
# nothing: on bash >= 4.4 the buggy line passes regardless of whether the fix
# is present. To be genuinely discriminating this test must run under real
# bash 3.2, so it uses the official `bash:3.2` Docker image. It also extracts
# the arg-parsing block directly out of _orch/bootstrap.sh by source markers
# (not a hand-copied idiom), so a future regression on that exact code is
# caught, not just on a paraphrase of it.
#
# Verified manually against both versions of line 80 before this test was
# committed: fails with "unbound variable" against
# `set -- "${bootstrap_args[@]}"`, passes against
# `set -- ${bootstrap_args[@]+"${bootstrap_args[@]}"}`.

setup() {
  ORCH_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not available -- cannot exercise real bash 3.2 semantics"
  fi
  if ! docker image inspect bash:3.2 >/dev/null 2>&1 && ! docker pull bash:3.2 >/dev/null 2>&1; then
    skip "bash:3.2 docker image unavailable (no network / pull failed)"
  fi
}

# Pulls the --name arg-parsing block (name_flag="" ... set -- ...) straight out
# of bootstrap.sh so this test tracks the real production source, not a copy.
extract_parse_block() {
  awk '/^name_flag=""/,/^set -- /' "$ORCH_ROOT/_orch/bootstrap.sh"
}

@test "bootstrap.sh's --name arg-parsing block survives an empty bootstrap_args under bash 3.2" {
  block="$(extract_parse_block)"
  [ -n "$block" ]
  # Sanity: the block we extracted actually contains the line under test.
  [[ "$block" == *'bootstrap_args[@]'* ]]

  # `--name test` is consumed entirely by the --name case, so bootstrap_args
  # stays empty -- exactly the failure mode from issue #98 (also hit by bare
  # `orch up`, which starts with zero args and never populates the array).
  run docker run --rm -i bash:3.2 bash -c '
    set -euo pipefail
    '"$block"'
    echo "OK args=$#"
  ' bash --name test

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK args=0"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "bootstrap.sh's --name arg-parsing block survives zero args (bare 'orch up') under bash 3.2" {
  block="$(extract_parse_block)"

  run docker run --rm -i bash:3.2 bash -c '
    set -euo pipefail
    '"$block"'
    echo "OK args=$#"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK args=0"* ]]
  [[ "$output" != *"unbound variable"* ]]
}
