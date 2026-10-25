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
  run timeout 10 bash -c "'$REPORT' w1 done < <(sleep 30)"
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
