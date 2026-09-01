#!/usr/bin/env bats
# The guard's own test (issue #134/#139 half a): tests/lint/no-inert-assertions.sh
# is exercised against fixture trees built under BATS_TEST_TMPDIR, never against
# the real tests/ tree, so this file can plant real inert assertions without
# touching anything the lint job itself scans.
#
# Fixture bodies below spell the bats test-declaration keyword as "@" "test"
# (concatenated at write time via printf) rather than a literal `@test` at
# column 0 -- bats-core's own preprocessor scans a .bats file's raw text for
# lines starting with `@test`, including inside a heredoc, so a literal
# occurrence here would register as a spurious extra test in THIS file.

GUARD="$BATS_TEST_DIRNAME/lint/no-inert-assertions.sh"
AT_TEST='@test'

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_ROOT/tests"
  cd "$FIXTURE_ROOT" || return 1
  git init -q .
  git config user.email test@test
  git config user.name test
}

commit_fixture() {
  git add -A
  git commit -q -m fixture
}

@test "flags an inert two-space-indent negation, naming file and line" {
  {
    printf '%s "inert" {\n' "$AT_TEST"
    printf '  ! grep -q boom "$f"\n'
    printf '  [ -e "$marker" ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/example.bats:2"* ]]
}

@test "flags an inert negation nested in a for loop at 4-space indent" {
  {
    printf '%s "loop inert" {\n' "$AT_TEST"
    printf '  for f in a b; do\n'
    printf '    ! grep -q boom "$f"\n'
    printf '  done\n'
    printf '  [ -e "$marker" ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/example.bats:3"* ]]
}

@test "flags an inert tab-indented negation" {
  {
    printf '%s "tab inert" {\n' "$AT_TEST"
    printf '\t! grep -q boom "$f"\n'
    printf '\t[ -e "$marker" ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests/example.bats:2"* ]]
}

@test "does not flag a final-position negation" {
  {
    printf '%s "final ok" {\n' "$AT_TEST"
    printf '  setup_thing\n'
    printf '  ! grep -q boom "$f"\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 0 ]
}

@test "does not flag a negation with an explicit || exit failure path" {
  {
    printf '%s "flock guard" {\n' "$AT_TEST"
    printf '  ! command -v flock >/dev/null 2>&1 || { echo "flock still on PATH"; exit 1; }\n'
    printf '  do_the_rest\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 0 ]
}

@test "does not flag a negation waived by a preceding # inert-ok: comment" {
  {
    printf '%s "waived" {\n' "$AT_TEST"
    printf '  if [ "$status" -eq 0 ]; then\n'
    printf '    [[ "$output" == *"ok"* ]]\n'
    printf '    # inert-ok: last statement of the if branch, which is itself final.\n'
    printf '    ! kill -0 "$BG_PID" 2>/dev/null\n'
    printf '  fi\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 0 ]
}

@test "does not flag if/while/until/elif/run negations" {
  {
    printf '%s "control-flow negations" {\n' "$AT_TEST"
    printf '  if ! command -v docker >/dev/null 2>&1; then\n'
    printf '    skip "no docker"\n'
    printf '  fi\n'
    printf '  while ! ready; do\n'
    printf '    sleep 1\n'
    printf '  done\n'
    printf '  until ! busy; do\n'
    printf '    sleep 1\n'
    printf '  done\n'
    printf '  run ! grep -q boom "$f"\n'
    printf '  [ "$status" -eq 0 ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "flags a locally-redefined refute_grep" {
  {
    printf 'refute_grep() {\n'
    printf '  [ "$(grep -c -- "$1" "$2" 2>/dev/null || true)" -eq 0 ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"local refute_* helper"* ]]
}

@test "clean tree reports a scanned-file count" {
  {
    printf '%s "ok" {\n' "$AT_TEST"
    printf '  [ -e "$marker" ]\n'
    printf '}\n'
  } > tests/example.bats
  commit_fixture
  run bash "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (1 files scanned)"* ]]
}
