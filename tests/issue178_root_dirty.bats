#!/usr/bin/env bats
# Issue #178 (#152 direction 2): heartbeat root_dirty_tick flags Bash-made writes
# into the target repo's main checkout (which the PreToolUse hook cannot see).
# Hermetic: scratch git repo, ORCH_ROOT in the bats tmp dir, no tmux, no claude.

ORCH_DIR_SRC="$BATS_TEST_DIRNAME/../_orch"

setup() {
  R="$BATS_TEST_TMPDIR/r"; mkdir -p "$R"
  export ORCH_ROOT="$R/toolkit" PROJ="$R/proj"
  mkdir -p "$ORCH_ROOT/_orch"
  git init -q -b main "$PROJ"
  git -C "$PROJ" config user.email t@example.com
  git -C "$PROJ" config user.name t
  mkdir -p "$PROJ/_orch"
  echo c > "$PROJ/_orch/config.json"; echo x > "$PROJ/f.sh"
  git -C "$PROJ" add -A; git -C "$PROJ" commit -q -m init
  echo '{}' > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  mkdir -p "$WORKERS_DIR" "$STATE_DIR"
  echo dirty >> "$PROJ/_orch/config.json"   # operator's own uncommitted edit
}

worker() { # <id> <mode> [repo]
  jq -n --arg id "$1" --arg m "$2" --arg r "${3:-$PROJ}" \
    '{id:$id,status:"working",mode:$m,target_repo:$r}' > "$WORKERS_DIR/$1.json"
}
baseline() { root_baseline_write "${2:-$PROJ}" "$1"; }
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
events() { nlines "$STATE_DIR/events.jsonl"; }
inbox() { nlines "$INBOX"; }

@test "tick reports new tracked+untracked dirt once, not baseline, re-alerts after clear" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"; echo t > "$PROJ/new.bats"
  root_dirty_tick
  [ "$(events)" -eq 1 ]; [ "$(inbox)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [ "$(jq -r .event <<<"$ev")" = root-dirty ]
  [[ "$ev" == *f.sh* ]]; [[ "$ev" == *new.bats* ]]; [[ "$ev" != *config.json* ]]
  [[ "$ev" == *w1* ]]
  root_dirty_tick
  [ "$(events)" -eq 1 ]; [ "$(inbox)" -eq 1 ]
  git -C "$PROJ" checkout -q f.sh
  root_dirty_tick; [ "$(events)" -eq 1 ]
  echo z >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 2 ]; [ "$(inbox)" -eq 2 ]
}

@test "no event when only the baseline entry is present" {
  worker w1 worktree; baseline w1
  root_dirty_tick
  [ "$(events)" -eq 0 ]; [ "$(inbox)" -eq 0 ]
}

@test "no event with zero live workers" {
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "no event for a no-worktree worker even when the root is dirtied" {
  worker w1 no-worktree
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "done workers do not count as live" {
  worker w1 worktree; baseline w1
  jq '.status="done"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "zero worktree-mode workers: tick runs no git" {
  fb="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fb"
  printf '#!/usr/bin/env bash\necho x >> "%s/git.calls"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$fb/git"
  chmod +x "$fb/git"
  worker w1 no-worktree
  PATH="$fb:$PATH" root_dirty_tick
  [ ! -e "$BATS_TEST_TMPDIR/git.calls" ]
}

@test "two worktree workers on one repo run git once" {
  worker w1 worktree; worker w2 worktree; baseline w1; baseline w2
  fb="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fb"
  real="$(command -v git)"
  printf '#!/usr/bin/env bash\necho x >> "%s/git.calls"\nexec %s "$@"\n' "$BATS_TEST_TMPDIR" "$real" > "$fb/git"
  chmod +x "$fb/git"
  PATH="$fb:$PATH" root_dirty_tick
  [ "$(nlines "$BATS_TEST_TMPDIR/git.calls")" -eq 1 ]
}

@test "spawn writes a baseline for worktree mode (target repo), none for --no-worktree; clean removes it" {
  stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in list-sessions) echo nosuch178;; capture-pane) echo "> ready for shortcuts";; esac\nexit 0\n' > "$stub/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"
  chmod +x "$stub/tmux" "$stub/claude"
  export SESSION_NAME=nosuch178
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' > "$ORCH_ROOT/_orch/config.json"
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO
  sp() { env PATH="$stub:$PATH" PROJECT_ROOT="$PROJ" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" "$@"; }
  run sp w1 sonnet task; [ "$status" -eq 0 ]
  f="$(root_baseline_file "$PROJ" w1)"
  [ -f "$f" ]; grep -q '_orch/config.json' "$f"
  run sp w2 sonnet task --no-worktree; [ "$status" -eq 0 ]
  [ ! -e "$(root_baseline_file "$PROJ" w2)" ]
  run env PATH="$stub:$PATH" PROJECT_ROOT="$PROJ" "$ORCH_DIR_SRC/clean.sh" w1
  [ ! -e "$f" ]
}

@test "baseline key includes the repo: same id in another repo is a separate file" {
  other="$R/other"; git init -q -b main "$other"
  [ "$(root_baseline_file "$PROJ" w1)" != "$(root_baseline_file "$other" w1)" ]
}

@test "operator edit between two worker spawns does not alert; union of baselines governs" {
  worker w1 worktree; baseline w1
  echo op >> "$PROJ/f.sh"          # operator edit between spawns
  worker w2 worktree; baseline w2
  root_dirty_tick
  [ "$(events)" -eq 0 ]
  echo n > "$PROJ/later.txt"       # new after both spawns
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [[ "$ev" == *later.txt* ]]; [[ "$ev" != *'"f.sh'* ]]
  [[ "$ev" == *w1* ]]; [[ "$ev" == *w2* ]]
}

@test "a worker's write before a later spawn is caught when ticked first" {
  worker w1 worktree; baseline w1
  echo w >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "worker without a baseline file suppresses the repo (cannot tell operator from worker)" {
  worker w1 worktree
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "operator staging a baseline entry does not alert (paths compared, not XY codes)" {
  worker w1 worktree; baseline w1
  git -C "$PROJ" add _orch/config.json
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "reported record is forgotten once no worktree worker is live" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  jq '.status="done"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  git -C "$PROJ" checkout -q f.sh
  root_dirty_tick
  worker w2 worktree; baseline w2
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 2 ]
}
