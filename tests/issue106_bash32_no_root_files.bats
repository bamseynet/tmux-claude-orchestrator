#!/usr/bin/env bats
# Regression test for issue #106: the bash32 CI job's docker step ran as
# root (`apk add` needs it) with the checkout bind-mounted in (`-v
# "$PWD":/repo`), so anything the container wrote -- `./orch up` creates
# `_orch/state/` -- landed root-owned in the host tree. `orch clean` then
# fails with "Permission denied" on the root-owned files, leaving a
# half-torn-down worker that needs sudo to remove. CI itself never noticed
# (hosted runners are discarded per run); this only ever bit local
# reproduction, which is the only way anyone verifies the job still works.
#
# The fix: don't bind-mount the working tree at all. Pipe it into the
# container as a tarball and unpack it inside the container's own
# filesystem, so nothing the (root) container does can touch the host tree.
#
# This test extracts the actual docker invocation out of ci.yml -- not a
# hand-copied paraphrase -- and runs it for real against a scratch
# directory, then asserts no file under that directory changed ownership.
# Not hermetic: needs a working `docker` daemon and network access to pull
# the pinned bash:3.2 image (same requirement as
# tests/issue98_bash32_empty_array.bats, ~15-20s).

setup() {
  ORCH_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BASH32_IMAGE="$(cat "$BATS_TEST_DIRNAME/bash32-image.txt")"
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not available -- cannot exercise the real container isolation"
  fi
  if ! docker image inspect "$BASH32_IMAGE" >/dev/null 2>&1 && ! docker pull "$BASH32_IMAGE" >/dev/null 2>&1; then
    skip "bash:3.2 docker image unavailable (no network / pull failed)"
  fi

  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH"
  # A throwaway git checkout of this repo, so the extracted step (which
  # does `git ls-files`, `./orch up`, etc.) has something real to run
  # against -- exactly what the CI checkout gives it.
  git clone -q --local --no-hardlinks "$ORCH_ROOT" "$SCRATCH/repo"
}

# Pulls the CI step's docker invocation straight out of ci.yml by source
# markers, the same technique tests/issue98_bash32_empty_array.bats uses on
# bootstrap.sh: track the real production script, not a paraphrase of it.
extract_docker_step() {
  awk '
    /^          tar -cf - --exclude=\.git/ { in_step = 1 }
    in_step { print }
    in_step && /^            \x27$/ { exit }
  ' "$ORCH_ROOT/.github/workflows/ci.yml"
}

@test "ci.yml's bash32 docker step no longer bind-mounts the checkout" {
  step="$(extract_docker_step)"
  # shellcheck disable=SC2016  # single-quoted: matching a literal string, not expanding one
  [[ "$step" != *'-v "$PWD"'* ]]
  [[ "$step" == *"tar -cf -"* ]]
}

@test "ci.yml's bash32 docker step leaves no root-owned files in the checkout it runs against" {
  step="$(extract_docker_step)"
  [ -n "$step" ]

  run bash -c "cd '$SCRATCH/repo' && BASH32_IMAGE='$BASH32_IMAGE' && $step"
  echo "$output"
  [ "$status" -eq 0 ]

  # `find -user root` needs no special privilege to query; it just reports
  # what it finds. On the old bind-mount design this reliably found
  # _orch/state/* owned by root (verified manually before this fix).
  root_owned="$(find "$SCRATCH/repo" -user root 2>/dev/null)"
  [ -z "$root_owned" ]
}
