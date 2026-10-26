#!/usr/bin/env bats
# Issue #177: spawn must refuse (before any state write) when an uncleaned
# workers/<id>.json is recorded against a DIFFERENT, still-existing target repo.
# Hermetic: real scratch git repos as siblings, PATH-stubbed tmux/claude.

ORCH_DIR_SRC="$BATS_TEST_DIRNAME/../_orch"
LIB="$ORCH_DIR_SRC/lib.sh"

mkrepo() { # <path>
  git init -q -b main "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  echo "$1" > "$1/f.txt"
  git -C "$1" add f.txt
  git -C "$1" commit -q -m init
}

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "nosuch177" ;;
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  # Hermetic against host git config: a global excludesfile (e.g. one ignoring
  # .claude/settings.local.json) or commit.gpgsign would otherwise change results.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"; mkdir -p "$XDG_CONFIG_HOME"
  R="$BATS_TEST_TMPDIR/r"
  mkdir -p "$R"
  export ORCH_ROOT="$R/toolkit" A="$R/a" B="$R/b"
  mkrepo "$ORCH_ROOT"; mkrepo "$A"; mkrepo "$B"
  mkdir -p "$ORCH_ROOT/_orch"
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
  export SESSION_NAME="nosuch177" ORCH_ALLOW_UNRELATED_REPO=1
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO
  STATE="$ORCH_ROOT/_orch/state"
  WORKERS="$STATE/workers"
  mkdir -p "$WORKERS"
  QUEUE="$STATE/queue.jsonl"
}

libcall() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }
spawn_in() { local repo="$1"; shift; env PROJECT_ROOT="$repo" "$ORCH_DIR_SRC/spawn.sh" "$@"; }
rec() { # <status> [repo]: a record for w1 against repo (default a)
  jq -n --arg s "$1" --arg t "${2-$A}" '{id:"w1",status:$s,updated:"2000-01-01T00:00:00Z"} + (if $t=="" then {} else {target_repo:$t} end)' > "$WORKERS/w1.json"
}
snapshot() { # prints b's git state + queue
  git -C "$B" worktree list; git -C "$B" branch
  cat "$QUEUE" 2>/dev/null || true
}
# drop a repo's w1 worktree+branch so the next spawn creates fresh (a reused
# worktree carries the first spawn's untracked .claude/settings.local.json, so it
# is not "clean" and spawn's reuse check refuses it)
reset_wt() { # <repo>
  local w; w="$(libcall worker_wdir "$1" w1)"
  git -C "$1" worktree remove --force "$w" 2>/dev/null || true
  git -C "$1" worktree prune
  git -C "$1" branch -D "$(libcall worker_branch w1)" >/dev/null 2>&1 || true
}
log_file() { find "$ORCH_ROOT" -name orch.log -print -quit; }

expect_spawned() { # diagnostics: show why a spawn that should succeed did not
  [ "$status" -eq 0 ] || { echo "spawn rc=$status: $output" >&2; tail -5 "$(log_file)" >&2; return 1; }
}

assert_refused() { # cmd run already; compares to pre-snapshot
  [ "$status" -ne 0 ]
  [[ "$output" == *"worker 'w1' is already recorded against $A (not $B)"* ]]
  cmp "$WORKERS/w1.json" "$BATS_TEST_TMPDIR/w1.before"
  [ "$(snapshot)" = "$(cat "$BATS_TEST_TMPDIR/snap.before")" ]
  tail -1 "$(log_file)" | grep -q "spawn refused for w1"   # this run's refusal, not an earlier one
}
before() { cp "$WORKERS/w1.json" "$BATS_TEST_TMPDIR/w1.before"; snapshot > "$BATS_TEST_TMPDIR/snap.before"; }

@test "refused for every uncleaned status recorded against a" {
  for st in spawning working needs-input done spawn-failed queued; do
    rec "$st"; before
    run spawn_in "$B" w1 sonnet "task"
    assert_refused
  done
}

@test "refused on the --after enqueue path; no record or queue written" {
  rec working; before
  run spawn_in "$B" w1 sonnet "task" --after x
  assert_refused
}

@test "refused on the gate-full enqueue path; no record or queue written" {
  jq '.thresholds.max_workers=0' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$ORCH_ROOT/_orch/config.json"
  rec working; before
  run spawn_in "$B" w1 sonnet "task"
  assert_refused
}

@test "same repo is not blocked (done/spawn-failed), incl. symlink and trailing slash" {
  ln -s "$A" "$R/a-link"
  for st in done spawn-failed; do for p in "$A" "$R/a-link" "$A/"; do
    rec "$st"
    run spawn_in "$p" w1 sonnet "task"
    expect_spawned
    [[ "$output" != *refused* ]]
    [ "$(jq -r .status "$WORKERS/w1.json")" = "working" ]
    reset_wt "$A"
  done; done
}

@test "not blocked: no target_repo, vanished repo, or record cleaned" {
  rec working ""
  run spawn_in "$B" w1 sonnet "task"
  expect_spawned
  [ "$(jq -r .target_repo "$WORKERS/w1.json")" = "$B" ]
  rm -f "$WORKERS/w1.json"; reset_wt "$B"
  rec working "$R/gone"
  run spawn_in "$B" w1 sonnet "task"
  expect_spawned
  [ "$(jq -r .target_repo "$WORKERS/w1.json")" = "$B" ]
  rm -f "$WORKERS/w1.json"; reset_wt "$B"
  run spawn_in "$B" w1 sonnet "task"
  [ "$status" -eq 0 ]
}

@test "drain: a queued w1 against b with no a-record launches against b" {
  run spawn_in "$B" w1 sonnet "task" --after x
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$WORKERS/w1.json")" = "queued" ]
  [ "$(jq -r .target_repo "$WORKERS/w1.json")" = "$B" ]
  run spawn_in "$B" w1 sonnet "task"   # what drain re-invokes: same repo, own queued record
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$WORKERS/w1.json")" = "working" ]
}
