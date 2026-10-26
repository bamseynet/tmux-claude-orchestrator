#!/usr/bin/env bats
# Issue #149: worker worktree paths must depend on the TARGET repo, not just
# ORCH_ROOT, and a worktree whose git-common-dir is another repo must never be
# adopted. Hermetic: real scratch git repos as SIBLINGS, PATH-stubbed tmux/claude.

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
  list-sessions) echo "nosuch149" ;;
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  R="$BATS_TEST_TMPDIR/r"
  mkdir -p "$R"
  export ORCH_ROOT="$R/toolkit" A="$R/a" B="$R/b"
  mkrepo "$ORCH_ROOT"; mkrepo "$A"; mkrepo "$B"
  mkdir -p "$ORCH_ROOT/_orch"
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
  export SESSION_NAME="nosuch149" ORCH_ALLOW_UNRELATED_REPO=1
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO
  WORKERS="$ORCH_ROOT/_orch/state/workers"
  mkdir -p "$WORKERS"
}

libcall() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }
common_dir() { (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P); }
repo_seg() { basename "$(dirname "$(libcall worker_wdir "$1" lift)")"; } # the <repo-hash> path segment

# the pre-#149 layout: <repo>/../wt/<ORCH_HASH>/<id>
v86_wdir() { printf '%s/../wt/%s/%s' "$1" "$(bash -c 'source "$1"; printf %s "$ORCH_HASH"' _ "$LIB")" "$2"; }

@test "A: spawn refuses to adopt a worktree whose git-common-dir is another repo" {
  wdir="$(libcall worker_wdir "$A" lift)"; branch="$(libcall worker_branch lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$branch" "$wdir"
  rm -rf "$wdir"                                   # a keeps a stale registration
  git -C "$B" worktree add -q -B "$branch" "$wdir" # b's clean checkout now sits at that path
  libcall stamp_worktree_owner "$wdir"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -ne 0 ]
  [[ "$output" == *spawn-failed* ]]
  [ "$(jq -r .status "$WORKERS/lift.json")" = "spawn-failed" ]
  [ "$(common_dir "$wdir")" = "$(common_dir "$B")" ]
}

@test "A: worktree_matches_expected rejects a stale-registered path checked out by another repo" {
  wdir="$(libcall worker_wdir "$A" lift)"; branch="$(libcall worker_branch lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$branch" "$wdir"
  rm -rf "$wdir"
  git -C "$B" worktree add -q -B "$branch" "$wdir"
  run libcall worktree_matches_expected "$A" "$wdir" "$branch"
  [ "$status" -ne 0 ]
  run libcall worktree_matches_expected "$B" "$wdir" "$branch"
  [ "$status" -eq 0 ]
}

@test "B: a leftover lift in repo a does not block lift in sibling repo b" {
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -eq 0 ]
  wa="$(libcall worker_wdir "$A" lift)"
  head_a="$(git -C "$wa" rev-parse HEAD)"
  run env PROJECT_ROOT="$B" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -eq 0 ]
  [[ "$output" != *spawn-failed* ]]
  wb="$(libcall worker_wdir "$B" lift)"
  [ "$(common_dir "$wb")" = "$(common_dir "$B")" ]
  [ -d "$wa" ]
  [ "$(common_dir "$wa")" = "$(common_dir "$A")" ]
  [ "$(git -C "$wa" rev-parse HEAD)" = "$head_a" ]
}

@test "B: worker_wdir differs between sibling repos, equal for the same repo via symlink or trailing slash" {
  [ "$(libcall worker_wdir "$A" lift)" != "$(libcall worker_wdir "$B" lift)" ]
  ln -s "$A" "$R/a-link"
  [ "$(repo_seg "$A")" = "$(repo_seg "$R/a-link")" ]
  [ "$(repo_seg "$A")" = "$(repo_seg "$A/")" ]
  [ "$(repo_seg "$A")" != "$(repo_seg "$B")" ]
}

mk_v86() { # <repo> <id>: a worker created at the current (pre-#149) layout
  local repo="$1" id="$2" wdir
  wdir="$(v86_wdir "$repo" "$id")"
  mkdir -p "$(dirname "$wdir")"
  git -C "$repo" worktree add -q -B "$(libcall worker_branch "$id")" "$wdir"
  libcall stamp_worktree_owner "$wdir"
  jq -n --arg id "$id" --arg t "$repo" '{id:$id,status:"done",updated:"2000-01-01T00:00:00Z",target_repo:$t}' > "$WORKERS/$id.json"
  echo "$wdir"
}

@test "upgrade: clean removes a worker living at the pre-#149 layout" {
  wdir="$(mk_v86 "$A" old)"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/clean.sh" old
  [ "$status" -eq 0 ]
  [ ! -e "$wdir" ]
  [ "$(git -C "$A" worktree list | wc -l)" -eq 1 ]
  ! git -C "$A" show-ref --verify --quiet "refs/heads/$(libcall worker_branch old)"
}

@test "upgrade: watchdog prune_dead_worktree removes a pre-#149 layout worktree" {
  wdir="$(mk_v86 "$A" old)"
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  prune_dead_worktree "$A" old
  [ ! -e "$wdir" ]
  ! git -C "$A" show-ref --verify --quiet "refs/heads/$(libcall worker_branch old)"
}

@test "upgrade: watchdog worker_branch_ahead sees commits in a pre-#149 layout worktree" {
  wdir="$(mk_v86 "$A" old)"
  echo more > "$wdir/g.txt"; git -C "$wdir" add g.txt; git -C "$wdir" commit -q -m work
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  run worker_branch_ahead "$A" old
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "upgrade: collect finds the branch of a pre-#149 layout worker" {
  mk_v86 "$A" old >/dev/null
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/collect.sh" old --base main
  [ "$status" -eq 0 ]
  [ "$(jq -r .branch_exists <<<"$output")" = "true" ]
}

@test "upgrade: respawning an id whose clean worktree is at the pre-#149 layout reuses it" {
  wdir="$(mk_v86 "$A" old)"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/spawn.sh" old sonnet "task"
  [ "$status" -eq 0 ]
  [[ "$output" != *spawn-failed* ]]
  [[ "$output" == *"$wdir"* ]] || grep -q "spawned old" <<<"$output"
  [ ! -e "$(libcall worker_wdir "$A" old)" ]
}
