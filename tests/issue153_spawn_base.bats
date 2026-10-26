#!/usr/bin/env bats
# Hermetic tests for issue #153: spawn must cut the worker worktree from the
# remote base (origin/${ORCH_BASE_BRANCH:-main}), not the target checkout's HEAD.

setup() {
  unset ORCH_ROOT SESSION_NAME ORCH_BASE_BRANCH
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  list-sessions) echo "$SESSION_NAME" ;;\n  list-windows) exit 0 ;;\n  capture-pane) echo "> ready for shortcuts" ;;\nesac\nexit 0\n' > "$STUBBIN/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"
  SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state"
  cat > "$ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  OTHER="$BATS_TEST_TMPDIR/other"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$PROJECT_ROOT" 2>/dev/null
  _cfg "$PROJECT_ROOT"
  echo hi > "$PROJECT_ROOT/f.txt"
  echo '.claude/settings.local.json' > "$PROJECT_ROOT/.gitignore"
  git -C "$PROJECT_ROOT" add f.txt .gitignore
  git -C "$PROJECT_ROOT" commit -q -m init
  git -C "$PROJECT_ROOT" push -q origin main
  git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
  _cfg "$OTHER"
  export PROJECT_ROOT ORCH_ROOT="$ROOT"
}

_cfg() { git -C "$1" config user.email t@example.com; git -C "$1" config user.name t; }

# push a commit to origin/<branch> from the second clone; echo its sha
_push_other() { # <branch> <file>
  git -C "$OTHER" fetch -q origin
  if git -C "$OTHER" rev-parse -q --verify "origin/$1" >/dev/null; then
    git -C "$OTHER" checkout -q -B "$1" "origin/$1"
  else
    git -C "$OTHER" checkout -q -B "$1" origin/main
  fi
  echo "$2" > "$OTHER/$2"; git -C "$OTHER" add "$2"; git -C "$OTHER" commit -q -m "$2"
  git -C "$OTHER" push -q origin "$1"
  git -C "$OTHER" rev-parse HEAD
}

_wdir() { bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "$PROJECT_ROOT" '"$1"; }

@test "stale local main: worker contains commit pushed to origin/main" {
  # No pre-fetch: spawn's own fetch must bring X in.
  X="$(_push_other main x.txt)"
  ! git -C "$PROJECT_ROOT" cat-file -e "$X^{commit}" 2>/dev/null
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  git -C "$(_wdir w1)" merge-base --is-ancestor "$X" HEAD
}

@test "target checkout on feature branch: worker excludes its WIP, includes origin/main" {
  X="$(_push_other main x.txt)"
  git -C "$PROJECT_ROOT" switch -q -c feature
  echo w > "$PROJECT_ROOT/w.txt"; git -C "$PROJECT_ROOT" add w.txt; git -C "$PROJECT_ROOT" commit -q -m wip
  W="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  wd="$(_wdir w1)"
  git -C "$wd" merge-base --is-ancestor "$X" HEAD
  ! git -C "$wd" merge-base --is-ancestor "$W" HEAD
}

@test "fetch failure: spawn still succeeds from last-known origin/main and logs it" {
  # Make last-known origin/main differ from local main/HEAD so a HEAD fallback
  # can't pass this test by accident.
  _push_other main x.txt >/dev/null
  git -C "$PROJECT_ROOT" fetch -q origin
  [ "$(git -C "$PROJECT_ROOT" rev-parse origin/main)" != "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]
  git -C "$PROJECT_ROOT" remote set-url origin "$BATS_TEST_TMPDIR/nonexistent.git"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ -d "$(_wdir w1)" ]
  grep -q 'git fetch origin failed' "$ROOT/_orch/state/orch.log"
  [ "$(git -C "$(_wdir w1)" rev-parse HEAD)" = "$(git -C "$PROJECT_ROOT" rev-parse origin/main)" ]
}

@test "no remote: falls back to HEAD and records base" {
  git -C "$PROJECT_ROOT" remote remove origin
  H="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(git -C "$(_wdir w1)" rev-parse HEAD)" = "$H" ]
  [ "$(jq -r .base "$ROOT/_orch/state/workers/w1.json")" = "main" ]
  [ "$(jq -r .base_sha "$ROOT/_orch/state/workers/w1.json")" = "$H" ]
}

@test "worker branch does not track the remote base branch" {
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  br="$(git -C "$(_wdir w1)" rev-parse --abbrev-ref HEAD)"
  [ -z "$(git -C "$PROJECT_ROOT" config --get "branch.$br.merge" || true)" ]
}

@test "ORCH_BASE_BRANCH=develop: based on origin/develop" {
  git -C "$OTHER" push -q origin main:develop
  D="$(_push_other develop d.txt)"
  export ORCH_BASE_BRANCH=develop
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(git -C "$(_wdir w1)" rev-parse HEAD)" = "$D" ]
  [ "$(jq -r .base "$ROOT/_orch/state/workers/w1.json")" = "origin/develop" ]
}

@test "dirty target checkout, HEAD and branch untouched" {
  _push_other main x.txt >/dev/null
  echo dirty >> "$PROJECT_ROOT/f.txt"
  before="$(git -C "$PROJECT_ROOT" status --porcelain)"; head0="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(git -C "$PROJECT_ROOT" status --porcelain)" = "$before" ]
  [ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" = "$head0" ]
  [ "$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)" = main ]
}

@test "status JSON records base and base_sha" {
  _push_other main x.txt >/dev/null
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  f="$ROOT/_orch/state/workers/w1.json"
  [ "$(jq -r .base "$f")" = "origin/main" ]
  [ "$(jq -r .base_sha "$f")" = "$(git -C "$(_wdir w1)" rev-parse HEAD)" ]
}

@test "ORCH_BASE_BRANCH only exists locally: based on local branch, not origin/HEAD" {
  git -C "$PROJECT_ROOT" branch develop
  _push_other main x.txt >/dev/null
  export ORCH_BASE_BRANCH=develop
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(git -C "$(_wdir w1)" rev-parse HEAD)" = "$(git -C "$PROJECT_ROOT" rev-parse develop)" ]
  [ "$(jq -r .base "$ROOT/_orch/state/workers/w1.json")" = "develop" ]
}

@test "HEAD fallback records the sha, not the moving HEAD ref" {
  git -C "$PROJECT_ROOT" remote remove origin
  export ORCH_BASE_BRANCH=nope
  H="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(jq -r .base "$ROOT/_orch/state/workers/w1.json")" = "$H" ]
}

@test "fetch runs before the spawn gate (a queued spawn has already refreshed origin)" {
  # The network fetch must not sit between the gate's live-worker count and the
  # status write, or concurrent spawns can all pass the gate and overrun max_workers.
  X="$(_push_other main x.txt)"
  jq '.thresholds.max_workers = 0' "$ROOT/_orch/config.json" > "$ROOT/c.tmp" && mv "$ROOT/c.tmp" "$ROOT/_orch/config.json"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$ROOT/_orch/state/workers/w1.json")" = queued ]
  [ "$(git -C "$PROJECT_ROOT" rev-parse origin/main)" = "$X" ]
}

@test "reused clean worktree still records base and base_sha" {
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  rm -f "$ROOT/_orch/state/workers/w1.json"
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  f="$ROOT/_orch/state/workers/w1.json"
  [ "$(jq -r .base "$f")" = "origin/main" ]
  [ "$(jq -r .base_sha "$f")" = "$(git -C "$PROJECT_ROOT" rev-parse origin/main)" ]
}

@test "origin/HEAD fallback records the concrete branch it names, not the symref" {
  git -C "$PROJECT_ROOT" remote set-head origin main
  export ORCH_BASE_BRANCH=nope
  run "$SPAWN" w1 sonnet "t"
  [ "$status" -eq 0 ]
  [ "$(jq -r .base "$ROOT/_orch/state/workers/w1.json")" = "origin/main" ]
}

@test "concurrent spawn fetches are serialised: a held fetch lock skips the fetch, never hangs" {
  command -v flock >/dev/null || skip "flock(1) not available"
  X="$(_push_other main x.txt)"
  lock="$ROOT/_orch/state/workers/.spawn-fetch.lock"
  mkdir -p "$(dirname "$lock")"
  flock "$lock" sleep 20 & holder=$!
  sleep 0.5
  ORCH_LOCK_TIMEOUT=1 run "$SPAWN" w1 sonnet "t"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  grep -q 'fetch lock busy' "$ROOT/_orch/state/orch.log"
  # lock held => no fetch => X not yet in the project's refs
  ! git -C "$PROJECT_ROOT" cat-file -e "$X^{commit}" 2>/dev/null
}
