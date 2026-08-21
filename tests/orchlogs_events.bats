#!/usr/bin/env bats
# Hermetic tests for issue #19: every worker event (report.sh, watchdog.sh,
# spawn.sh) must be TEE'd to an append-only $STATE_DIR/events.jsonl, in addition
# to the existing (destructively-drained) inbox.jsonl, so there is a durable
# audit trail of done/needs-input/stalled/spawn-failed events that survives
# heartbeat.sh's read-and-truncate drain.

REPORT="$BATS_TEST_DIRNAME/../_orch/report.sh"

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
}

@test "report.sh appends every event to the durable events.jsonl, not just the inbox" {
  run "$REPORT" w1 done
  [ "$status" -eq 0 ]

  f="$ORCH_ROOT/_orch/state/events.jsonl"
  [ -f "$f" ]
  run cat "$f"
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"event":"done"'* ]]
}

@test "report.sh's events.jsonl survives the inbox being drained (truncated) by heartbeat.sh" {
  "$REPORT" w2 working
  "$REPORT" w2 needs-input

  # Simulate heartbeat.sh's destructive inbox drain.
  : > "$ORCH_ROOT/_orch/state/inbox.jsonl"

  "$REPORT" w2 done

  run wc -l < "$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$output" -eq 3 ]
  run wc -l < "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [ "$output" -eq 1 ]
}

@test "watchdog.sh liveness_check tees a stalled event to events.jsonl" {
  export SESSION_NAME="test"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJECT_ROOT"

  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  stall=90; needs_input_realert=600; review_idle=99999999
  realert_base=90; realert_max=1800

  printf '{"id":"w3","status":"working","updated":"x"}\n' > "$WORKERS_DIR/w3.json"

  liveness_check w3 "some unchanging pane text" 1000
  liveness_check w3 "some unchanging pane text" 1091

  run cat "$STATE_DIR/events.jsonl"
  [[ "$output" == *'"id":"w3"'* ]]
  [[ "$output" == *'"event":"stalled"'* ]]
}

@test "watchdog.sh liveness_check tees a ready-for-review event to events.jsonl" {
  export SESSION_NAME="test"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email test@example.com
  git -C "$PROJECT_ROOT" config user.name test
  git -C "$PROJECT_ROOT" checkout -q -B main
  echo hello > "$PROJECT_ROOT/f.txt"
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init

  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/watchdog.sh"
  stall=90; needs_input_realert=600; review_idle=300
  realert_base=90; realert_max=1800

  printf '{"id":"w4","status":"working","updated":"x"}\n' > "$WORKERS_DIR/w4.json"

  wdir="$(worker_wdir "$PROJECT_ROOT" w4)"
  git -C "$PROJECT_ROOT" worktree add -q -B "$(worker_branch w4)" "$wdir" >/dev/null
  echo change > "$wdir/g.txt"
  git -C "$wdir" add g.txt
  git -C "$wdir" commit -q -m "worker commit"

  liveness_check w4 "idle pane" 1000
  liveness_check w4 "idle pane" 1301

  run cat "$STATE_DIR/events.jsonl"
  [[ "$output" == *'"event":"ready-for-review"'* ]]
}

@test "spawn.sh tees a spawn-failed event to events.jsonl (never just the inbox)" {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "orch" ;;
  list-windows)  exit 0 ;;
  capture-pane)  echo 'Welcome to Claude Code' ;;   # never becomes ready
  show-buffer)   exit 1 ;;
esac
exit 0
EOF

  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  mkdir -p "${args[$((${#args[@]}-1))]}"
fi
exit 0
EOF

  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$STUBBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git" "$STUBBIN/claude" "$STUBBIN/sleep"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0, "spawn_inject_retries": 1 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON

  run "$BATS_TEST_DIRNAME/../_orch/spawn.sh" w5 sonnet "do the thing" --no-worktree
  [[ "$output" == *"spawn-failed w5"* ]]

  f="$ORCH_ROOT/_orch/state/events.jsonl"
  [ -f "$f" ]
  run cat "$f"
  [[ "$output" == *'"id":"w5"'* ]]
  [[ "$output" == *'"event":"spawn-failed"'* ]]
}
