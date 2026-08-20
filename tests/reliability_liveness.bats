#!/usr/bin/env bats
# Hermetic tests for liveness_check() (issue #50): the per-window sweep that
# replaces the old fire-once "alerted" flag with bounded/backoff re-alerting, adds
# a needs-input escalation distinct from the dead-worker sweep, and adds the
# committed-work-idle "ready-for-review" detector.
#
# watchdog.sh guards its main loop behind a "sourced vs executed" check, so we can
# source it and call liveness_check() directly with explicit <now> timestamps
# instead of sleeping (same technique as watchdog_dead.bats / watchdog_rl_cooldown).

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/root"
  export SESSION_NAME="test"
  mkdir -p "$ORCH_ROOT/_orch"

  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  git -C "$PROJECT_ROOT" checkout -q -B main
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init

  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  # Small thresholds so the test doesn't need huge timestamp deltas.
  stall=90
  needs_input_realert=600
  review_idle=300
  realert_base=90
  realert_max=1800
}

mkworker() { # <id> <status>
  printf '{"id":"%s","status":"%s","updated":"x"}\n' "$1" "$2" > "$WORKERS_DIR/$1.json"
}

@test "liveness_check: pane change resets the episode, no alert" {
  mkworker w1 working
  liveness_check w1 "some busy output esc to interrupt" 1000
  [ ! -s "$INBOX" ]
  run cat "$STATE_DIR/.wd-w1"
  [[ "$output" == *$'\n'1000$'\n'0$'\n'0 ]]
}

@test "liveness_check: working worker under stall threshold does not alert" {
  mkworker w1 working
  liveness_check w1 "idle pane text" 1000
  liveness_check w1 "idle pane text" 1050   # age=50 < stall=90
  [ ! -s "$INBOX" ]
}

@test "liveness_check: working worker past stall threshold emits 'stalled'" {
  mkworker w1 working
  liveness_check w1 "idle pane text" 1000
  liveness_check w1 "idle pane text" 1090   # age=90 >= stall=90
  run cat "$INBOX"
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"event":"stalled"'* ]]
}

@test "liveness_check: active spinner suppresses the stall alert" {
  mkworker w1 working
  liveness_check w1 "esc to interrupt" 1000
  liveness_check w1 "esc to interrupt" 1200
  [ ! -s "$INBOX" ]
}

@test "liveness_check: does not re-alert before the backoff interval elapses" {
  mkworker w1 working
  liveness_check w1 "idle pane text" 1000
  liveness_check w1 "idle pane text" 1090   # first alert, count=1
  : > "$INBOX"
  liveness_check w1 "idle pane text" 1150   # only 60s later, base=90 -> not due
  [ ! -s "$INBOX" ]
}

@test "liveness_check: re-alerts (with backoff) instead of firing once" {
  mkworker w1 working
  liveness_check w1 "idle pane text" 1000
  liveness_check w1 "idle pane text" 1090   # 1st alert (count 0->1)
  : > "$INBOX"
  liveness_check w1 "idle pane text" 1180   # base(90)*2^0=90 since last -> due
  run cat "$INBOX"
  [[ "$output" == *'"event":"stalled"'* ]]
  : > "$INBOX"
  liveness_check w1 "idle pane text" 1270   # only +90 since last (need +180) -> not due
  [ ! -s "$INBOX" ]
  liveness_check w1 "idle pane text" 1360   # +180 since 1180 -> due
  run cat "$INBOX"
  [[ "$output" == *'"event":"stalled"'* ]]
}

@test "liveness_check: needs-input under its own threshold does not alert" {
  mkworker w1 needs-input
  liveness_check w1 "waiting at prompt" 1000
  liveness_check w1 "waiting at prompt" 1300   # age=300 < needs_input_realert=600
  [ ! -s "$INBOX" ]
}

@test "liveness_check: abandoned needs-input emits a distinct 'needs-input-stalled' event" {
  mkworker w1 needs-input
  liveness_check w1 "waiting at prompt" 1000
  liveness_check w1 "waiting at prompt" 1600   # age=600 >= needs_input_realert=600
  run cat "$INBOX"
  [[ "$output" == *'"event":"needs-input-stalled"'* ]]
  [[ "$output" != *'"event":"needs-input"'* ]]
  [[ "$output" != *'"event":"stalled"'* ]]
}

@test "liveness_check: idle status other than working/spawning/needs-input never stall-alerts" {
  mkworker w1 done
  liveness_check w1 "finished" 1000
  liveness_check w1 "finished" 5000
  [ ! -s "$INBOX" ]
}

@test "liveness_check: idle worker with commits ahead emits ready-for-review" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w1)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" commit -q -m "unmerged work"
  mkworker w1 needs-input

  liveness_check w1 "idle at prompt" 1000
  liveness_check w1 "idle at prompt" 1300   # age=300 >= review_idle=300
  run cat "$INBOX"
  [[ "$output" == *'"event":"ready-for-review"'* ]]
  [[ "$output" == *'"id":"w1"'* ]]
}

@test "liveness_check: idle worker with a clean branch never emits ready-for-review" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  mkworker w1 done

  liveness_check w1 "idle at prompt" 1000
  liveness_check w1 "idle at prompt" 1400
  run cat "$INBOX"
  [[ "$output" != *'"event":"ready-for-review"'* ]]
}

@test "liveness_check: ready-for-review re-alerts with backoff, not fire-once" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w1)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" commit -q -m "unmerged work"
  mkworker w1 done

  liveness_check w1 "idle at prompt" 1000
  liveness_check w1 "idle at prompt" 1300   # 1st ready-for-review alert
  : > "$INBOX"
  liveness_check w1 "idle at prompt" 1350   # only +50s, base=90 -> not due
  [ ! -s "$INBOX" ]
  liveness_check w1 "idle at prompt" 1390   # +90s since 1300 -> due
  run cat "$INBOX"
  [[ "$output" == *'"event":"ready-for-review"'* ]]
}

@test "liveness_check: ready-for-review clears once the branch is merged/clean" {
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w1)" "$(worker_wdir "$PROJECT_ROOT" w1)" >/dev/null
  echo more > "$(worker_wdir "$PROJECT_ROOT" w1)/g.txt"
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" add g.txt
  git -C "$(worker_wdir "$PROJECT_ROOT" w1)" commit -q -m "unmerged work"
  mkworker w1 done

  liveness_check w1 "idle at prompt" 1000
  liveness_check w1 "idle at prompt" 1300
  [ -e "$STATE_DIR/.review-w1" ]

  # Fast-forward main to include the worktree's commit -> nothing ahead anymore.
  git -C "$PROJECT_ROOT" merge -q "$(worker_branch w1)"
  : > "$INBOX"
  liveness_check w1 "idle at prompt" 1400
  [ ! -s "$INBOX" ]
  [ ! -e "$STATE_DIR/.review-w1" ]
}
