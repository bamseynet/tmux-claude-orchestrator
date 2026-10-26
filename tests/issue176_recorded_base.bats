#!/usr/bin/env bats
# Issue #176: watchdog's worker_branch_ahead and merge.sh must honour the
# base/base_sha spawn recorded (#153/#170) and ORCH_BASE_BRANCH. Real git with a
# bare origin (not the fake-git stub); gh is stubbed on PATH and logs its argv.

# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  unset ORCH_BASE_BRANCH ORCH_REPO_EXPLICIT
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"
  cp -R "$BATS_TEST_DIRNAME/../_orch/." "$ORCH_ROOT/_orch/"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  P="$PROJECT_ROOT"
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git init -q "$P"
  git -C "$P" config user.email t@example.com
  git -C "$P" config user.name t
  git -C "$P" checkout -q -B main
  git -C "$P" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  echo a > "$P/f"; git -C "$P" add f; git -C "$P" commit -q -m m0
  git -C "$P" push -q origin main
  git -C "$P" checkout -q -b develop
  git -C "$P" commit -q --allow-empty -m d1
  git -C "$P" commit -q --allow-empty -m d2
  git -C "$P" push -q origin develop
  git -C "$P" checkout -q main
  git -C "$P" fetch -q origin

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$ORCH_ROOT/_orch/watchdog.sh"

  mkdir -p "$WORKERS_DIR"
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"; : > "$GH_LOG"; export GH_LOG
  cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") exit 1 ;;
  "pr create") echo "https://example.invalid/pr/1"; exit 0 ;;
esac
exit 0
GH
  chmod +x "$STUB/gh"
}

# mkworker <id> <base-ref> <commits> [record-base]
mkworker() {
  local id="$1" ref="$2" n="$3" rec="${4-$2}" sha wd i
  sha="$(git -C "$P" rev-parse "$ref")"
  wd="$(worker_wdir "$P" "$id")"
  git -C "$P" worktree add -q --no-track -b "$(worker_branch "$id")" "$wd" "$sha" >/dev/null
  git -C "$wd" config user.email t@example.com; git -C "$wd" config user.name t
  for ((i = 0; i < n; i++)); do git -C "$wd" commit -q --allow-empty -m "w$i"; done
  jq -n --arg b "$rec" --arg s "$sha" --arg t "$P" \
    '{status:"working", base:$b, base_sha:$s, target_repo:$t}' > "$WORKERS_DIR/$id.json"
}

@test "ahead: recorded develop base, 1 worker commit -> 1" {
  mkworker w1 origin/develop 1
  run worker_branch_ahead "$P" w1
  [ "$output" = "1" ]
}

@test "ahead: recorded develop base, 0 worker commits -> 0" {
  mkworker w2 origin/develop 0
  run worker_branch_ahead "$P" w2
  [ "$output" = "0" ]
}

@test "ahead: recorded base ref gone, base_sha still resolves -> 1" {
  mkworker w1 origin/develop 1
  git -C "$P" update-ref -d refs/remotes/origin/develop
  run worker_branch_ahead "$P" w1
  [ "$output" = "1" ]
}

@test "ahead: no record + ORCH_BASE_BRANCH=develop counts against origin/develop" {
  mkworker w1 origin/develop 1
  rm "$WORKERS_DIR/w1.json"
  ORCH_BASE_BRANCH=develop run worker_branch_ahead "$P" w1
  [ "$output" = "1" ]
}

wd_vars() {
  INBOX="$BATS_TEST_TMPDIR/inbox"; : > "$INBOX"
  mkdir -p "$STATE_DIR"
  stall=90; needs_input_realert=600; review_idle=300; background_wait=1800
  realert_base=90; realert_max=1800
}

@test "watchdog: idle 0-commit develop worker emits no ready-for-review" {
  mkworker w2 origin/develop 0
  wd_vars
  liveness_check w2 "idle" 1000
  liveness_check w2 "idle" 1400
  refute_grep 'ready-for-review' "$INBOX"
  [ ! -f "$STATE_DIR/events.jsonl" ] || refute_grep 'ready-for-review' "$STATE_DIR/events.jsonl"
}

@test "watchdog: idle 1-commit develop worker still emits ready-for-review" {
  mkworker w1 origin/develop 1
  wd_vars
  liveness_check w1 "idle" 1000
  liveness_check w1 "idle" 1400
  grep -q ready-for-review "$INBOX"
}

@test "merge: recorded develop base -> gh pr create --base develop" {
  mkworker w1 origin/develop 1
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base develop ' "$GH_LOG"
}

@test "merge: --base X wins over the record" {
  mkworker w1 origin/develop 1
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1 --base release
  grep -q 'gh pr create --base release ' "$GH_LOG"
}

@test "merge: recorded origin/master -> --base master" {
  git -C "$P" push -q origin develop:master && git -C "$P" fetch -q origin
  mkworker w1 origin/develop 1 origin/master
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base master ' "$GH_LOG"
}

@test "merge: no record -> --base main" {
  mkworker w1 origin/develop 1
  rm "$WORKERS_DIR/w1.json"
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base main ' "$GH_LOG"
}

@test "merge: no record + ORCH_BASE_BRANCH=trunk -> --base trunk" {
  mkworker w1 origin/develop 1
  rm "$WORKERS_DIR/w1.json"
  ORCH_BASE_BRANCH=trunk PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base trunk ' "$GH_LOG"
}

@test "merge: bare-SHA record falls back to ORCH_BASE_BRANCH/main" {
  sha="$(git -C "$P" rev-parse origin/develop)"
  mkworker w1 origin/develop 1 "$sha"
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base main ' "$GH_LOG"
}

@test "ahead: record wins over a conflicting ORCH_BASE_BRANCH" {
  mkworker w1 origin/develop 1
  ORCH_BASE_BRANCH=main run worker_branch_ahead "$P" w1
  [ "$output" = "1" ]
}

@test "ahead: no record + ORCH_BASE_BRANCH names a local-only branch -> counts against it" {
  git -C "$P" branch -q localdev origin/develop
  mkworker w1 origin/develop 1
  rm "$WORKERS_DIR/w1.json"
  ORCH_BASE_BRANCH=localdev run worker_branch_ahead "$P" w1
  [ "$output" = "1" ]
}

@test "collect: recorded develop base still drives the diff base" {
  mkworker w1 origin/develop 1
  run bash "$ORCH_ROOT/_orch/collect.sh" w1
  [ "$(jq -r .base <<< "$output")" = "origin/develop" ]
}

@test "merge: record wins over a conflicting ORCH_BASE_BRANCH" {
  mkworker w1 origin/develop 1
  ORCH_BASE_BRANCH=trunk PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base develop ' "$GH_LOG"
}

@test "merge: hex-looking branch name is still a branch, not a pinned sha" {
  git -C "$P" push -q origin develop:deadbeef && git -C "$P" fetch -q origin
  mkworker w1 origin/develop 1 origin/deadbeef
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base deadbeef ' "$GH_LOG"
}

@test "merge: recorded base branch pruned -> falls back to ORCH_BASE_BRANCH/main with a warning" {
  mkworker w1 origin/develop 1
  git -C "$P" update-ref -d refs/remotes/origin/develop
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base main ' "$GH_LOG"
  refute_grep 'base develop' "$GH_LOG"
  [[ "$output" == *"develop"*"no longer exists"* ]]
}

@test "merge: local-branch record (no origin/) that still exists locally is kept" {
  mkworker w1 develop 1 develop
  git -C "$P" update-ref -d refs/remotes/origin/develop
  PATH="$STUB:$PATH" run bash "$ORCH_ROOT/_orch/merge.sh" w1
  grep -q 'gh pr create --base develop ' "$GH_LOG"
}
