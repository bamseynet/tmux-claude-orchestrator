#!/usr/bin/env bats
# Issue #105: `orch:5` does `export ORCH_ROOT="${ORCH_ROOT:-$here}"` -- an
# already-set ORCH_ROOT is never re-resolved from $0's dirname, and because
# `orch` exports it, every nested invocation inherits it. That let an
# ambient ORCH_ROOT (a worker's launch env, a leftover shell export) make
# `./orch` silently act on a completely different install: it corrupted the
# live toolkit's .orch-version, hijacked a self-referential test fixture
# (#97), and produced a false "cannot reproduce" during #114.
#
# Fix: refuse when an inherited ORCH_ROOT disagrees with the running
# script's own location, mirroring ensure_related_repo()'s
# ORCH_ALLOW_UNRELATED_REPO precedent in _orch/lib.sh. Legitimate use (an
# _orch/*.sh script sourcing lib.sh and inheriting ORCH_ROOT from the `orch`
# that invoked it) is unaffected: that ORCH_ROOT was set by THIS SAME orch's
# own $here on the way in, so it always agrees.

setup() {
  # This test's own launch env may itself carry an ambient ORCH_ROOT (see
  # tests/issue97_orch_update_self_exec.bats for the same hazard) -- unset it
  # so each test starts from a clean slate and controls ORCH_ROOT explicitly.
  unset ORCH_ROOT

  T="$BATS_TEST_TMPDIR/T"
  mkdir -p "$T/_orch/state"
  cp "$BATS_TEST_DIRNAME/../orch" "$T/orch"
  chmod +x "$T/orch"

  # $D deliberately lives OUTSIDE any BATS_*_TMPDIR root (bats' own
  # BATS_TMPDIR defaults to the bare /tmp, so a plain mktemp under /tmp would
  # NOT be outside it -- use $HOME instead) to model an ambient ORCH_ROOT
  # that leaked in from somewhere other than this test's own isolation (the
  # actual shape of the #97/#114 incidents: a real toolkit checkout under
  # ~/repos, not a scratch dir) -- as opposed to a test that isolates
  # ORCH_ROOT under its own BATS_TEST_TMPDIR on purpose, covered separately
  # below. Cleaned up in teardown since it is not a bats tmp dir bats will
  # remove for us.
  D="$(mktemp -d "$HOME/.orch105-ambient-test.XXXXXX")"
  mkdir -p "$D/_orch/state"
}

teardown() {
  [ -n "${D:-}" ] && rm -rf "$D"
}

@test "orch: refuses when inherited ORCH_ROOT disagrees with the script's own location" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$D" "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -ne 0 ]
  [[ "$output" == *"ORCH_ROOT"* ]]
  [[ "$output" == *"$D"* ]]
  [[ "$output" == *"$T"* ]]
  # Must refuse before doing anything -- not just print a warning and act on
  # $D anyway (that's the exact silent-hijack shape #105 is about).
  [[ "$output" != *"no heartbeat log yet"* ]]
}

@test "orch: ORCH_ALLOW_ROOT_MISMATCH=1 overrides the mismatch refusal deliberately" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$D" ORCH_ALLOW_ROOT_MISMATCH=1 \
    "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
}

@test "orch: a matching ORCH_ROOT (same install) proceeds normally, no refusal" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$T" "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
}

@test "orch: an unset ORCH_ROOT (normal case) resolves from \$0 and proceeds normally" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO -u ORCH_ROOT "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
}

@test "orch: a trailing slash on ORCH_ROOT is normalized, not treated as a mismatch" {
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$T/" "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
}

@test "orch: a hermetic bats test deliberately isolating ORCH_ROOT under its own tmp dir is not refused" {
  # Same idiom as lib.sh's issue #68 leak guard: a test pointing ORCH_ROOT at
  # a throwaway scratch dir under BATS_TEST_TMPDIR, while invoking the real
  # repo's orch script, is deliberate isolation, not the #105 hazard -- it
  # already guarantees no write lands in a real toolkit. BATS_TEST_FILENAME
  # is set for every bats @test automatically; no need to export it by hand.
  ISOLATED_ROOT="$BATS_TEST_TMPDIR/isolated_root"
  mkdir -p "$ISOLATED_ROOT/_orch/state"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$ISOLATED_ROOT" \
    "$BATS_TEST_DIRNAME/../orch" --repo "$T" logs heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"no heartbeat log yet"* ]]
}

@test "orch: an isolated ORCH_ROOT that does not exist yet is still recognized, not treated as a mismatch" {
  # tests/clean.bats' "orch help documents clean and kill" is the real
  # example: setup() exports ORCH_ROOT=$BATS_TEST_TMPDIR/root for every test
  # in the file, but this particular test only runs `orch help` and never
  # creates that directory. `cd "$ORCH_ROOT"` fails on a nonexistent dir, so
  # the guard must fall back to comparing the raw (trailing-slash-stripped)
  # path rather than treating cd failure as an automatic mismatch.
  NEVER_CREATED="$BATS_TEST_TMPDIR/never_created_root"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$NEVER_CREATED" \
    "$BATS_TEST_DIRNAME/../orch" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux + Claude Code orchestrator"* ]]
}

@test "orch: an ambient ORCH_ROOT pointing OUTSIDE any bats tmp root still refuses even under bats" {
  # Reproduces the actual shape of the #97/#114 incidents: ORCH_ROOT was not
  # deliberately isolated by the test, it leaked in pointing at a real,
  # non-scratch toolkit -- here modeled by $D, which is NOT under any
  # BATS_*_TMPDIR. This must refuse exactly like the non-bats case, not be
  # waved through just because a bats run is in progress.
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ROOT="$D" "$T/orch" --repo "$T" logs heartbeat
  [ "$status" -ne 0 ]
  [[ "$output" == *"ORCH_ROOT"* ]]
}
