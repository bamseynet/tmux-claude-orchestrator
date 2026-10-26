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

@test "B: a leftover lift in repo a is refused in sibling b, leaving a's worktree, branch and record untouched (#177)" {
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -eq 0 ]
  wa="$(libcall worker_wdir "$A" lift)"
  head_a="$(git -C "$wa" rev-parse HEAD)"
  cp "$WORKERS/lift.json" "$BATS_TEST_TMPDIR/lift.before"
  run env PROJECT_ROOT="$B" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -ne 0 ]
  cmp "$WORKERS/lift.json" "$BATS_TEST_TMPDIR/lift.before"
  [ ! -e "$(libcall worker_wdir "$B" lift)" ]
  [ -d "$wa" ]
  [ "$(common_dir "$wa")" = "$(common_dir "$A")" ]
  [ "$(git -C "$wa" rev-parse HEAD)" = "$head_a" ]
}

@test "B: after clean against a, lift spawns in sibling b and a's state stays gone (#177)" {
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -eq 0 ]
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -eq 0 ]
  run env PROJECT_ROOT="$B" "$ORCH_DIR_SRC/spawn.sh" lift sonnet "task"
  [ "$status" -eq 0 ]
  [[ "$output" != *spawn-failed* ]]
  wb="$(libcall worker_wdir "$B" lift)"
  [ "$(common_dir "$wb")" = "$(common_dir "$B")" ]
  [ "$(git -C "$A" worktree list | wc -l)" -eq 1 ]
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

# collect.sh never looks at the worktree path (only the branch name, which #149
# did not change): this is a regression guard, not coverage of resolve_worker_wdir.
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
  grep -q "spawned old" <<<"$output"
  [ ! -e "$(libcall worker_wdir "$A" old)" ]
}

@test "upgrade: sibling b never adopts or cleans repo a's pre-#149 layout worktree" {
  wdir="$(mk_v86 "$A" old)"
  [ "$(libcall resolve_worker_wdir "$A" old)" = "$wdir" ]
  [ "$(libcall resolve_worker_wdir "$B" old)" = "$(libcall worker_wdir "$B" old)" ]
  jq --arg t "$B" '.target_repo=$t' "$WORKERS/old.json" > "$WORKERS/old.tmp" && mv "$WORKERS/old.tmp" "$WORKERS/old.json"
  run env PROJECT_ROOT="$B" "$ORCH_DIR_SRC/clean.sh" old
  [ "$status" -eq 0 ]
  [ -d "$wdir" ]
  [ "$(common_dir "$wdir")" = "$(common_dir "$A")" ]
}

@test "clean and prune refuse to rm -rf another repo's checkout sitting at this repo's path" {
  wdir="$(libcall worker_wdir "$A" lift)"; branch="$(libcall worker_branch lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$branch" "$wdir"
  rm -rf "$wdir"                                   # a keeps a stale registration
  git -C "$B" worktree add -q -B "$branch" "$wdir" # b's checkout now sits at a's path
  libcall stamp_worktree_owner "$wdir"
  jq -n --arg t "$A" '{id:"lift",status:"done",updated:"2000-01-01T00:00:00Z",target_repo:$t}' > "$WORKERS/lift.json"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a worktree of"* ]]
  [ "$(common_dir "$wdir")" = "$(common_dir "$B")" ]
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  prune_dead_worktree "$A" lift
  [ "$(common_dir "$wdir")" = "$(common_dir "$B")" ]
}

@test "legacy: clean --sweep-legacy in repo a never deletes sibling b's pre-#86 ../wt/<id>" {
  lw="$R/wt/old"                      # pre-#86 layout, shared by sibling repos a and b
  git -C "$B" worktree add -q -B orch/old "$lw"
  jq -n '{id:"old",status:"done",updated:"2000-01-01T00:00:00Z"}' | jq --arg t "$A" '.target_repo=$t' > "$WORKERS/old.json"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/clean.sh" old --sweep-legacy
  [ "$status" -eq 0 ]
  [ -d "$lw" ]
  [ "$(common_dir "$lw")" = "$(common_dir "$B")" ]
}

@test "legacy: worker_branch_ahead ignores a sibling repo's pre-#86 ../wt/<id>" {
  lw="$R/wt/old"
  git -C "$B" worktree add -q -B orch/old "$lw"
  echo x > "$lw/g.txt"; git -C "$lw" add g.txt; git -C "$lw" commit -q -m work
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  run worker_branch_ahead "$A" old
  [ "$status" -ne 0 ]
  [ "$output" = "0" ]
}

@test "clean and prune still remove this repo's own worktree whose admin dir is gone" {
  wdir="$(libcall worker_wdir "$A" lift)"; branch="$(libcall worker_branch lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$branch" "$wdir"
  rm -rf "$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/worktrees"  # admin dir gone; .git file now dangles
  run git -C "$wdir" rev-parse --git-dir
  [ "$status" -ne 0 ]
  run libcall foreign_checkout "$wdir" "$A"
  [ "$status" -ne 0 ]
  jq -n --arg t "$A" '{id:"lift",status:"done",updated:"2000-01-01T00:00:00Z",target_repo:$t}' > "$WORKERS/lift.json"
  run env PROJECT_ROOT="$A" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -eq 0 ]
  [ ! -e "$wdir" ]
  git -C "$A" worktree add -q -B "$branch" "$wdir"
  rm -rf "$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/worktrees"
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  prune_dead_worktree "$A" lift
  [ ! -e "$wdir" ]
}

@test "a dangling worktree of ANOTHER repo at this repo's path is still foreign" {
  wdir="$(libcall worker_wdir "$A" lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$B" worktree add -q -B x "$wdir"
  rm -rf "$(git -C "$B" rev-parse --path-format=absolute --git-common-dir)/worktrees"
  run libcall foreign_checkout "$wdir" "$A"
  [ "$status" -eq 0 ]
}

@test "same_repo ignores an exported GIT_DIR; worker_wdir ignores CDPATH" {
  run env GIT_DIR="$A/.git" bash -c 'source "$1"; same_repo "$2" "$3"' _ "$LIB" "$A" "$B"
  [ "$status" -ne 0 ]
  abs="$(libcall worker_wdir "$A" lift)"
  rel="$(cd "$R" && CDPATH="$R" bash -c 'source "$1"; worker_wdir a lift' _ "$LIB")"
  [ "$(basename "$(dirname "$abs")")" = "$(basename "$(dirname "$rel")")" ]
}

@test "same_repo/foreign_checkout stay correct on git < 2.31 (no --path-format)" {
  # Emulate old git: it echoes the unknown --path-format flag back and prints a
  # relative ".git" for a main checkout, so two top-level repos would look "same".
  real_git="$(command -v git)"
  OLDGIT="$BATS_TEST_TMPDIR/oldgit"; mkdir -p "$OLDGIT"
  cat > "$OLDGIT/git" <<STUB
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in --path-format=*) printf '%s\n' "\$a" ;; *) args+=("\$a") ;; esac
done
exec "$real_git" "\${args[@]}"
STUB
  chmod +x "$OLDGIT/git"
  wdir="$(libcall worker_wdir "$A" lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$(libcall worker_branch lift)" "$wdir"
  run env PATH="$OLDGIT:$PATH" bash -c 'source "$1"; same_repo "$2" "$3"' _ "$LIB" "$B" "$A"
  [ "$status" -ne 0 ]
  run env PATH="$OLDGIT:$PATH" bash -c 'source "$1"; foreign_checkout "$2" "$3"' _ "$LIB" "$B" "$A"
  [ "$status" -eq 0 ]
  run env PATH="$OLDGIT:$PATH" bash -c 'source "$1"; same_repo "$2" "$3"' _ "$LIB" "$wdir" "$A"
  [ "$status" -eq 0 ]
}

@test "prune_dead_worktree removes the emptied <repo-hash> and <ORCH_HASH> namespace dirs" {
  wdir="$(libcall worker_wdir "$A" lift)"
  mkdir -p "$(dirname "$wdir")"
  git -C "$A" worktree add -q -B "$(libcall worker_branch lift)" "$wdir"
  export PROJECT_ROOT="$A"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  prune_dead_worktree "$A" lift
  [ ! -e "$(dirname "$wdir")" ]
  [ ! -e "$(dirname "$(dirname "$wdir")")" ]
}

@test "same_repo: a plain non-checkout dir inside the repo is not a checkout of it" {
  mkdir -p "$A/plain"
  run libcall same_repo "$A/plain" "$A"
  [ "$status" -ne 0 ]
  libcall same_repo "$A" "$A"
}

@test "_git_common_dir climbs a symlink's TARGET, not the link's logical parent" {
  mkdir -p "$A/sub"
  mkrepo "$R/l"                       # a repo sitting at the symlink's logical parent
  ln -s "$A/sub" "$R/l/s"             # git prints ../.git for a subdir checkout
  [ "$(libcall _git_common_dir "$R/l/s")" = "$(common_dir "$A")" ]
}
