#!/usr/bin/env bats
# Issue #163 part C: a Stop that fires while the worker still has background work
# (Stop payload `background_tasks` / `session_crons`) is not "done". report.sh
# --hook reads the payload; the watchdog treats the resulting `waiting-bg` status
# with its own long timeout and never raises ready-for-review for it.
# Hermetic: ORCH_ROOT/PROJECT_ROOT are temp dirs; no tmux, no claude.

load helpers/refute.bash

REPORT="$BATS_TEST_DIRNAME/../_orch/report.sh"
SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"
  WJ="$ORCH_ROOT/_orch/state/workers/w1.json"
  INB="$ORCH_ROOT/_orch/state/inbox.jsonl"
  EVT="$ORCH_ROOT/_orch/state/events.jsonl"
}

BG='{"background_tasks":[{"type":"shell","status":"running"}],"session_crons":[]}'

@test "C4: --hook Stop with a running background task -> waiting-bg, events.jsonl only" {
  printf '%s' "$BG" | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "waiting-bg" ]
  grep -q '"event":"turn-ended"' "$EVT"
  grep -q '"id":"w1"' "$EVT"
  if [ -f "$INB" ]; then refute_grep '"id":"w1"' "$INB"; fi
}

@test "C4b: --hook Stop with only a non-empty session_crons -> waiting-bg" {
  printf '%s' '{"background_tasks":[],"session_crons":[{"id":"c1"}]}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "waiting-bg" ]
}

@test "C5a: --hook Stop with both arrays empty -> done + inbox event" {
  printf '%s' '{"background_tasks":[],"session_crons":[]}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "done" ]
  grep -q '"event":"done"' "$INB"
}

@test "C5b: --hook Stop with both arrays absent -> done (fail-open)" {
  printf '%s' '{"hook_event_name":"Stop"}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "done" ]
  grep -q '"event":"done"' "$INB"
}

@test "C5c: --hook Stop with unparseable payload -> done (fail-open), exit 0" {
  run bash -c "printf '%s' 'not json' | '$REPORT' w1 done --hook"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$WJ")" = "done" ]
  grep -q '"event":"done"' "$INB"
}

@test "C6: without --hook report.sh never reads stdin (no block)" {
  # An open pipe that never closes: a stray cat would hang until timeout kills it.
  # The writer must not inherit bats' fd 3 (or stderr): bats waits for every
  # holder of fd 3 to exit, so an orphaned `sleep 30` stalled the file run for
  # ~30s while --timing reported the test itself as fast. Close fd 3 and reap
  # the writer by its captured PID ($! of the process substitution).
  run timeout 10 bash -c "exec 4< <(exec sleep 30 3>&- 2>/dev/null); w=\$!; '$REPORT' w1 done <&4; rc=\$?; kill \"\$w\" 2>/dev/null; exit \$rc"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$WJ")" = "done" ]
  run timeout 10 "$REPORT" w1 dead </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$WJ")" = "dead" ]
}

@test "C6b: --hook with a non-done event ignores background_tasks" {
  printf '%s' "$BG" | "$REPORT" w1 needs-input --hook
  [ "$(jq -r .status "$WJ")" = "needs-input" ]
  grep -q '"event":"needs-input"' "$INB"
}

@test "C5d: --hook Stop with non-array / null background_tasks -> done (defensive)" {
  for p in '{"background_tasks":null}' '{"background_tasks":"abc"}' '{"background_tasks":5}' '{"session_crons":{"a":1}}' '[1,2]'; do
    rm -f "$WJ"
    printf '%s' "$p" | "$REPORT" w1 done --hook
    [ "$(jq -r .status "$WJ")" = "done" ]
  done
}

@test "C5e: --hook Stop whose background_tasks are all terminal -> done; unknown status -> waiting-bg" {
  printf '%s' '{"background_tasks":[{"status":"completed"},{"status":"Killed"}]}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "done" ]
  printf '%s' '{"background_tasks":[{"type":"novel","status":"mystery"}]}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "waiting-bg" ]
}

@test "C5f: a SubagentStop does not knock a worker out of waiting-bg" {
  printf '%s' "$BG" | "$REPORT" w1 done --hook
  "$REPORT" w1 subagent-done </dev/null
  [ "$(jq -r .status "$WJ")" = "waiting-bg" ]
  printf '%s' '{"background_tasks":[]}' | "$REPORT" w1 done --hook
  [ "$(jq -r .status "$WJ")" = "done" ]
}

@test "C5g: a late SubagentStop does not overwrite done / needs-input (deps, reap, re-alert)" {
  printf '%s' '{"background_tasks":[]}' | "$REPORT" w1 done --hook
  "$REPORT" w1 subagent-done </dev/null
  [ "$(jq -r .status "$WJ")" = "done" ]
  "$REPORT" w1 needs-input </dev/null
  "$REPORT" w1 subagent-done </dev/null
  [ "$(jq -r .status "$WJ")" = "needs-input" ]
  "$REPORT" w2 working </dev/null
  "$REPORT" w2 subagent-done </dev/null
  [ "$(jq -r .status "$ORCH_ROOT/_orch/state/workers/w2.json")" = "subagent-done" ]
}

# ---- watchdog ----

wd_setup() {
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email t@example.com
  git -C "$PROJECT_ROOT" config user.name t
  git -C "$PROJECT_ROOT" checkout -q -B main
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  stall=90; needs_input_realert=600; review_idle=300
  realert_base=90; realert_max=1800
}

mkworker() { printf '{"id":"%s","status":"%s","updated":"x"}\n' "$1" "$2" > "$WORKERS_DIR/$1.json"; }

ahead_commit() {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w1)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" commit -q -m "work"
}

@test "C7: waiting-bg worker with commits ahead and idle pane: no ready-for-review" {
  wd_setup
  ahead_commit
  mkworker w1 waiting-bg
  background_wait=100000
  liveness_check w1 "idle" 1000
  liveness_check w1 "idle" 1400
  [ ! -s "$INBOX" ] || refute_grep 'ready-for-review' "$INBOX"
}

@test "C8: waiting-bg: no 90s stall, nothing before background_wait, 'stalled' after" {
  wd_setup
  mkworker w1 waiting-bg
  background_wait=1800
  liveness_check w1 "idle" 1000
  liveness_check w1 "idle" 1200     # past stall=90, under background_wait
  [ ! -s "$INBOX" ]
  liveness_check w1 "idle" 2799     # age 1799
  [ ! -s "$INBOX" ]
  liveness_check w1 "idle" 2800     # age 1800
  grep -q '"event":"stalled"' "$INBOX"
}

@test "C3: config.json carries watchdog.background_wait_seconds default 1800" {
  [ "$(jq -r '.watchdog.background_wait_seconds' "$BATS_TEST_DIRNAME/../_orch/config.json")" = "1800" ]
}

@test "C9: a waiting-bg worker whose window is gone is orphaned (dead sweep reports it)" {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  run worker_is_orphaned $'a\nb' waiting-bg w1
  [ "$status" -eq 0 ]
  run worker_is_orphaned $'w1\nb' waiting-bg w1
  [ "$status" -ne 0 ]
}

@test "C10: waiting-bg re-alerts back off from background_wait, not the 90s realert base" {
  wd_setup
  mkworker w1 waiting-bg
  background_wait=1800
  liveness_check w1 "idle" 1000
  liveness_check w1 "idle" 2800     # first stalled alert
  [ "$(grep -c '"event":"stalled"' "$INBOX")" -eq 1 ]
  liveness_check w1 "idle" 2900     # +100s: a 90s base would re-alert here
  liveness_check w1 "idle" 4000
  [ "$(grep -c '"event":"stalled"' "$INBOX")" -eq 1 ]
  liveness_check w1 "idle" 4600     # +1800s
  [ "$(grep -c '"event":"stalled"' "$INBOX")" -eq 2 ]
}

@test "C11: a subagent-done worker whose window is gone is orphaned" {
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  run worker_is_orphaned $'a\nb' subagent-done w1
  [ "$status" -eq 0 ]
}

@test "C12: dead sweep reports a windowless waiting-bg worker dead but keeps its worktree/branch" {
  wd_setup
  ahead_commit
  mkworker w1 waiting-bg
  DEAD_CONFIRM_TICKS=1
  dead_sweep $'other'
  [ "$(jq -r .status "$WJ")" = "dead" ]
  [ -d "$(worker_wdir "$PROJECT_ROOT" w1)" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$(worker_branch w1)"
}
