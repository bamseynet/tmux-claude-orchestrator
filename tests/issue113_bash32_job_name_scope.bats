#!/usr/bin/env bats
# Regression test for issue #113: the bash32 CI job runs `bash -n` plus a
# single ./orch-up smoke path under real bash 3.2 -- it never runs bats. A
# job named "bash 3.2 compatibility smoke" reads, in a PR checks list, as
# far broader coverage than that: a reviewer sees a green tick and
# reasonably assumes the whole suite ran under 3.2, which it never did.
#
# This is the third instance of the same overstated-coverage failure mode
# in this repo (#102's `bash -n` comment, #104/#108's lib.sh:148), so the
# fix is pinned down here as a test on the job's displayed NAME -- the only
# part of the job a PR-checks-list reader ever actually looks at -- rather
# than trusted to a comment buried in the YAML that nobody reading the
# checks list will open.
#
# Hermetic: reads .github/workflows/ci.yml as text, no docker/bats/git
# subprocess needed.

bats_require_minimum_version 1.5.0

setup() {
  CI_YML="$BATS_TEST_DIRNAME/../.github/workflows/ci.yml"
}

# Pulls just the `name:` value of the `bash32:` job, the same way issue98's
# test pulls a block out of bootstrap.sh by source markers: track the real
# file, not a hand-copied paraphrase of it.
bash32_job_name() {
  awk '
    /^  bash32:/ { in_job = 1; next }
    in_job && /^    name:/ { sub(/^    name: */, ""); print; exit }
    in_job && /^  [a-zA-Z]/ { exit }
  ' "$CI_YML"
}

@test "bash32 job exists in ci.yml" {
  run bash32_job_name
  [ -n "$output" ]
}

@test "bash32 job's displayed name does not claim broad bash-3.2 coverage" {
  name="$(bash32_job_name)"
  # Guard against a broken/renamed extraction silently passing: an empty
  # $name would fall through the case below with no default arm and match
  # nothing, vacuously "passing" this coverage-overstatement check without
  # actually verifying anything.
  [ -n "$name" ]
  # The overstated name this issue is about: "bash 3.2 compatibility smoke"
  # (with or without a parenthetical) implies the whole codebase's behaviour
  # was verified under 3.2. It was not -- only syntax + one code path was.
  case "$name" in
    *'bash 3.2 compatibility smoke'*)
      echo "job name overstates coverage: $name" >&2
      return 1
      ;;
  esac
}

@test "bash32 job's displayed name states its actual scope (syntax + smoke, no bats)" {
  name="$(bash32_job_name)"
  [[ "$name" == *"syntax"* ]]
  [[ "$name" == *"no bats"* || "$name" == *"smoke"* ]]
  # Must not claim bats ran under this job -- bats only runs in the `test`
  # job's bash-5.x environment.
  [[ "$name" != *"bats"* || "$name" == *"no bats"* ]]
}

@test "bash32 job does not invoke the bats binary anywhere in its steps" {
  # If bats ever does get wired into this job, its name must stop claiming
  # "no bats" -- catch that drift here rather than leaving the name stale.
  # Matches an actual invocation ("bats tests/", "bats <file>.bats"), not
  # the word "bats" inside a prose comment explaining why it's absent.
  job_body="$(awk '/^  bash32:/{p=1} p{print} p && /^  [a-zA-Z]/ && !/^  bash32:/{exit}' "$CI_YML")"
  run ! grep -Eq '(^|[^a-zA-Z_-])bats ([a-zA-Z0-9_./-]+\.bats|tests/)' <<<"$job_body"
}
