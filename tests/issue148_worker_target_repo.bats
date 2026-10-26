#!/usr/bin/env bats
# Issue #148: a worker's target repo is recorded at spawn/queue time
# (workers/<id>.json and the queue record carry `target_repo`) and every later
# operation -- clean, reap, prune, collect, merge, the queue drain -- uses the
# RECORDED repo instead of re-resolving from its own environment.
#
# Hermetic: scratch git repos as SIBLINGS under $BATS_TEST_TMPDIR/r (so the #149
# shared ../wt/<hash>/<id> path is present), PATH-stubbed tmux/claude, no live
# session. Real git throughout.

ORCH="$BATS_TEST_DIRNAME/../orch"
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
  list-sessions) echo "nosuch148" ;;
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
  export ORCH_ROOT="$R/toolkit" TARGET="$R/target" OTHER="$R/other"
  mkrepo "$ORCH_ROOT"; mkrepo "$TARGET"; mkrepo "$OTHER"
  mkdir -p "$ORCH_ROOT/_orch"
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
  export SESSION_NAME="nosuch148"
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO
  WORKERS="$ORCH_ROOT/_orch/state/workers"
  mkdir -p "$WORKERS"
}

teardown() {
  # background spawns started by the queue drain
  local p
  for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
}

libcall() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

# mkworker <repo> <id> [record-target=1]: worktree made the way spawn.sh does,
# plus a status file (recording target_repo unless record-target=0).
mkworker() {
  local repo="$1" id="$2" rec="${3:-1}" wdir branch
  wdir="$(libcall worker_wdir "$repo" "$id")"
  branch="$(libcall worker_branch "$id")"
  mkdir -p "$(dirname "$wdir")"
  git -C "$repo" worktree add -q -B "$branch" "$wdir"
  libcall stamp_worktree_owner "$wdir"
  if [ "$rec" = 1 ]; then
    jq -n --arg id "$id" --arg t "$repo" '{id:$id,status:"done",updated:"2000-01-01T00:00:00Z",target_repo:$t}' > "$WORKERS/$id.json"
  else
    jq -n --arg id "$id" '{id:$id,status:"done",updated:"2000-01-01T00:00:00Z"}' > "$WORKERS/$id.json"
  fi
}

assert_clean_of() { # <repo> <id>: no worktree entry, no branch
  [ "$(git -C "$1" worktree list | wc -l)" -eq 1 ]
  ! git -C "$1" show-ref --verify --quiet "refs/heads/$(libcall worker_branch "$2")"
}

@test "clean without --repo tears down the RECORDED repo, not PROJECT_ROOT" {
  mkworker "$TARGET" lift
  before="$(git -C "$ORCH_ROOT" worktree list; git -C "$ORCH_ROOT" branch --list)"
  run env PROJECT_ROOT="$ORCH_ROOT" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -eq 0 ]
  assert_clean_of "$TARGET" lift
  [ "$before" = "$(git -C "$ORCH_ROOT" worktree list; git -C "$ORCH_ROOT" branch --list)" ]
  [ ! -e "$WORKERS/lift.json" ]
}

@test "same id twice: spawn, clean from another repo, spawn again registers in target" {
  mkworker "$TARGET" lift
  run env PROJECT_ROOT="$ORCH_ROOT" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -eq 0 ]
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" lift sonnet "again"
  [ "$status" -eq 0 ]
  [[ "$output" != *spawn-failed* ]]
  git -C "$TARGET" worktree list | grep -q "$(libcall worker_branch lift)"
  [ "$(jq -r .target_repo "$WORKERS/lift.json")" = "$TARGET" ]
}

@test "watchdog reap_terminal_workers cleans the recorded repo" {
  mkworker "$TARGET" lift
  export PROJECT_ROOT="$ORCH_ROOT"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  reap_terminal_workers 0 "" "$(date -u +%s)"
  assert_clean_of "$TARGET" lift
}

@test "watchdog prune_dead_worktree via resolve_worker_proj uses the recorded repo" {
  mkworker "$TARGET" lift
  export PROJECT_ROOT="$ORCH_ROOT"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  prune_dead_worktree "$(resolve_worker_proj lift)" lift
  assert_clean_of "$TARGET" lift
}

@test "spawn records target_repo in the spawning/working status file" {
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" w1 sonnet "task"
  [ "$status" -eq 0 ]
  [ "$(jq -r .target_repo "$WORKERS/w1.json")" = "$TARGET" ]
}

@test "spawn --after records target_repo in queue record and status file" {
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" w2 sonnet "task" --after w1
  [ "$status" -eq 0 ]
  [ "$(jq -r .target_repo "$ORCH_ROOT/_orch/state/queue.jsonl")" = "$TARGET" ]
  [ "$(jq -r .target_repo "$WORKERS/w2.json")" = "$TARGET" ]
}

@test "gate-refused spawn records target_repo in queue record and status file" {
  echo '{"thresholds":{"max_workers":0,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" w3 sonnet "task"
  [ "$status" -eq 0 ]
  [[ "$output" == *queued* ]]
  [ "$(jq -r .target_repo "$ORCH_ROOT/_orch/state/queue.jsonl")" = "$TARGET" ]
  [ "$(jq -r .target_repo "$WORKERS/w3.json")" = "$TARGET" ]
}

drain_in() { # <project_root>: source heartbeat and drain once under that PROJECT_ROOT
  export PROJECT_ROOT="$1"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  drain_queue_if_room
  local i=0
  while [ "$i" -lt 150 ] && [ ! -e "$DRAIN_WDIR" ]; do sleep 0.1; i=$((i+1)); done
  wait   # let the drained spawn.sh finish before teardown removes the tmpdir
}

@test "queue drain under a different valid repo creates the worktree in the queued repo only" {
  echo '{"id":"w1","status":"done"}' > "$WORKERS/w1.json"
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" w2 sonnet "task" --after w1
  [ "$status" -eq 0 ]
  DRAIN_WDIR="$(libcall worker_wdir "$TARGET" w2)"
  drain_in "$OTHER"
  [ -d "$DRAIN_WDIR" ]
  git -C "$TARGET" worktree list | grep -q "$(libcall worker_branch w2)"
  [ "$(git -C "$OTHER" worktree list | wc -l)" -eq 1 ]
  ! git -C "$OTHER" show-ref --verify --quiet "refs/heads/$(libcall worker_branch w2)"
}

@test "queue drain carries the unrelated-repo override recorded at queue time" {
  # toolkit and target are unrelated histories: only ORCH_ALLOW_UNRELATED_REPO lets them spawn
  echo '{"id":"w1","status":"done"}' > "$WORKERS/w1.json"
  run env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" w2 sonnet "task" --after w1
  [ "$status" -eq 0 ]
  DRAIN_WDIR="$(libcall worker_wdir "$TARGET" w2)"
  drain_in "$OTHER"
  [ -d "$DRAIN_WDIR" ]
}

queue_record() { # <id> <target> <allow_unrelated>: a post-#148 --after-w1 queue record
  jq -nc --arg id "$1" --arg t "$2" --arg u "$3" \
    '{id:$id, model:"sonnet", task:"task", mode:"", resume:"", allow_csv:"", ts:"2000-01-01T00:00:00Z", reason:"dep", after:"w1", target_repo:$t, allow_unrelated:$u}' \
    >> "$ORCH_ROOT/_orch/state/queue.jsonl"
  jq -n --arg id "$1" --arg t "$2" '{id:$id,status:"queued",target_repo:$t}' > "$WORKERS/$1.json"
}

@test "queue drain does not leak the heartbeat's own unrelated-repo override into a record without one" {
  echo '{"id":"w1","status":"done"}' > "$WORKERS/w1.json"
  queue_record w2 "$TARGET" ""
  # the heartbeat itself runs with the override (e.g. inherited from `orch up`)
  export ORCH_ALLOW_UNRELATED_REPO=1 PROJECT_ROOT="$OTHER"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  drain_queue_if_room
  wait
  # the drain really ran: the record left the queue
  [ ! -s "$ORCH_ROOT/_orch/state/queue.jsonl" ]
  # ...but the spawn was refused by guard 0: nothing created in the queued repo
  [ ! -e "$(libcall worker_wdir "$TARGET" w2)" ]
  ! git -C "$TARGET" show-ref --verify --quiet "refs/heads/$(libcall worker_branch w2)" || return 1
  # the refused drain is surfaced, not left "queued" forever with its record popped
  [ "$(jq -r .status "$WORKERS/w2.json")" = "spawn-failed" ]
  grep -q '"id":"w2","event":"spawn-failed"' "$ORCH_ROOT/_orch/state/inbox.jsonl"
}

@test "queue drain of a record whose target repo vanished marks it spawn-failed, not queued forever" {
  echo '{"id":"w1","status":"done"}' > "$WORKERS/w1.json"
  queue_record w2 "$R/gone" "1"
  export PROJECT_ROOT="$OTHER"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  drain_queue_if_room
  wait
  [ ! -s "$ORCH_ROOT/_orch/state/queue.jsonl" ]
  [ "$(jq -r .status "$WORKERS/w2.json")" = "spawn-failed" ]
  [ "$(git -C "$OTHER" worktree list | wc -l)" -eq 1 ]
  # master is notified, and retention counts from the failure, not the 2000 queue ts
  grep -q '"id":"w2","event":"spawn-failed"' "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [ "$(jq -r .updated "$WORKERS/w2.json")" != "2000-01-01T00:00:00Z" ]
  [ "$(jq -r .updated "$WORKERS/w2.json")" != "null" ]
}

@test "queue drain of a vanished-target record with no status file still records spawn-failed" {
  echo '{"id":"w1","status":"done"}' > "$WORKERS/w1.json"
  queue_record w2 "$R/gone" "1"
  rm -f "$WORKERS/w2.json"
  export PROJECT_ROOT="$OTHER"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  drain_queue_if_room
  wait
  [ "$(jq -r .status "$WORKERS/w2.json")" = "spawn-failed" ]
  [ "$(jq -r .id "$WORKERS/w2.json")" = "w2" ]
  [ "$(jq -r .target_repo "$WORKERS/w2.json")" = "$R/gone" ]
  # seeded from the queue record so `orch status` doesn't render null model/task
  [ "$(jq -r .model "$WORKERS/w2.json")" = "sonnet" ]
  [ "$(jq -r .task "$WORKERS/w2.json")" = "task" ]
  [ "$(jq -r '.created // empty' "$WORKERS/w2.json")" != "" ]
}

@test "watchdog dead_sweep prunes a dead worker's worktree in the recorded repo" {
  mkworker "$TARGET" lift
  jq '.status="working"' "$WORKERS/lift.json" > "$WORKERS/lift.json.tmp" && mv "$WORKERS/lift.json.tmp" "$WORKERS/lift.json"
  export PROJECT_ROOT="$ORCH_ROOT" DEAD_CONFIRM_TICKS=1
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/watchdog.sh"
  dead_sweep ""
  assert_clean_of "$TARGET" lift
}

@test "orch --repo <other> prune does not claim to reap a worker clean.sh refused" {
  mkworker "$TARGET" lift
  run env ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" --repo "$OTHER" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"not reaped lift"* ]]
  [ -e "$WORKERS/lift.json" ]
  [ -d "$(libcall worker_wdir "$TARGET" lift)" ]
}

@test "orch --repo <other> clean refuses when it disagrees with the recorded repo" {
  mkworker "$TARGET" lift
  run env ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" --repo "$OTHER" clean lift
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TARGET"* ]]
  [ "$(git -C "$TARGET" worktree list | wc -l)" -eq 2 ]
  [ -e "$WORKERS/lift.json" ]
  [ -d "$(libcall worker_wdir "$TARGET" lift)" ]
}

@test "orch --repo <recorded repo> clean is accepted" {
  mkworker "$TARGET" lift
  run env ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH" --repo "$TARGET" clean lift
  [ "$status" -eq 0 ]
  assert_clean_of "$TARGET" lift
}

@test "legacy status file without target_repo cleans via PROJECT_ROOT as before" {
  mkworker "$TARGET" lift 0
  run env PROJECT_ROOT="$TARGET" "$ORCH_DIR_SRC/clean.sh" lift
  [ "$status" -eq 0 ]
  assert_clean_of "$TARGET" lift
}

@test "collect.sh finds the branch in the recorded repo regardless of PROJECT_ROOT" {
  mkworker "$TARGET" lift
  run env PROJECT_ROOT="$ORCH_ROOT" "$ORCH_DIR_SRC/collect.sh" lift --base main
  [ "$status" -eq 0 ]
  [ "$(jq -r .branch_exists <<<"$output")" = "true" ]
}

@test "merge.sh refuses an explicit repo that disagrees with the recorded one" {
  mkworker "$TARGET" lift
  run env PROJECT_ROOT="$OTHER" ORCH_REPO_EXPLICIT=1 "$ORCH_DIR_SRC/merge.sh" lift
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TARGET"* ]]
  # the refusal is a no-op: the worker's branch and status file survive
  git -C "$TARGET" show-ref --verify --quiet "refs/heads/$(libcall worker_branch lift)"
  [ -e "$WORKERS/lift.json" ]
}
