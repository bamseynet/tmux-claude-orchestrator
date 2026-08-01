#!/usr/bin/env bats
# Hermetic tests for the unified resource guard (issues #21 concurrency,
# #31 memory, #24 budget): _orch/lib.sh's check_spawn_gate() plus the queue
# helpers, and structural checks that spawn.sh/heartbeat.sh/hud.sh wire them in.
# No tmux window and no `claude` process is ever launched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
  # A permissive default config: high cap, no memory/budget pressure.
  cat > "$CONFIG" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON
}

worker_json() { # <id> <status>
  jq -n --arg id "$1" --arg s "$2" '{id:$id, status:$s}' > "$WORKERS_DIR/$1.json"
}

@test "live_worker_count excludes done and spawn-failed" {
  worker_json w1 working
  worker_json w2 "done"
  worker_json w3 spawn-failed
  worker_json w4 needs-input
  [ "$(live_worker_count)" -eq 2 ]
}

@test "check_spawn_gate passes when under every cap" {
  worker_json w1 working
  run check_spawn_gate
  [ "$status" -eq 0 ]
}

@test "check_spawn_gate refuses at the concurrency cap" {
  jq '.thresholds.max_workers = 1' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  worker_json w1 working
  if check_spawn_gate; then rc=0; else rc=1; fi
  [ "$rc" -eq 1 ]
  [[ "$GATE_REASON" == *"concurrency cap"* ]]
}

@test "check_spawn_gate refuses when min_free_mb + est_worker_mb exceeds real free memory" {
  jq '.thresholds.min_free_mb = 999999999 | .thresholds.est_worker_mb = 1' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  if check_spawn_gate; then rc=0; else rc=1; fi
  [ "$rc" -eq 1 ]
  [[ "$GATE_REASON" == *"insufficient memory"* ]]
}

@test "check_spawn_gate refuses when the next spawn would exceed budget.max_usd" {
  jq '.budget.enabled = true | .budget.max_usd = 1.0 | .budget.est_usd_per_worker = 0.5' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  jq -n '{spawns: 2}' > "$SPEND_FILE"   # est spend already $1.00; +$0.50 would exceed $1.00 cap
  if check_spawn_gate; then rc=0; else rc=1; fi
  [ "$rc" -eq 1 ]
  [[ "$GATE_REASON" == *"budget cap"* ]]
}

@test "check_spawn_gate allows spend right up to the cap" {
  jq '.budget.enabled = true | .budget.max_usd = 1.0 | .budget.est_usd_per_worker = 0.5' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  jq -n '{spawns: 1}' > "$SPEND_FILE"   # est spend $0.50; +$0.50 == $1.00 cap, not over
  run check_spawn_gate
  [ "$status" -eq 0 ]
}

@test "record_spend increments the persisted spawn counter" {
  [ "$(spend_count)" -eq 0 ]
  record_spend
  record_spend
  [ "$(spend_count)" -eq 2 ]
}

@test "queue_push then queue_pop returns FIFO order and drains the file" {
  queue_push '{"id":"a"}'
  queue_push '{"id":"b"}'
  run queue_pop
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"a"'* ]]
  run queue_pop
  [[ "$output" == *'"id":"b"'* ]]
  run queue_pop
  [ "$status" -eq 1 ]
}

@test "spawn.sh checks the unified gate before spawning" {
  grep -Fq 'check_spawn_gate' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  grep -Fq 'queue_push' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
}

@test "spawn.sh records spend only on a confirmed successful spawn" {
  grep -Fq 'record_spend' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
}

@test "heartbeat.sh drains the queue every tick" {
  grep -Fq 'drain_queue_if_room' "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
  grep -Fq 'check_spawn_gate' "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

@test "hud.sh surfaces the coarse spend estimate against budget.max_usd" {
  grep -Fq 'est_spend_usd' "$BATS_TEST_DIRNAME/../_orch/hud.sh"
  grep -Fq 'budget.max_usd' "$BATS_TEST_DIRNAME/../_orch/hud.sh"
}

@test "config.json defines the new thresholds and budget keys" {
  run jq -e '.thresholds.min_free_mb, .thresholds.est_worker_mb, .budget.max_usd, .budget.est_usd_per_worker' "$BATS_TEST_DIRNAME/../_orch/config.json"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md makes nested-team guidance memory-conditional" {
  grep -Fq 'min_free_mb' "$BATS_TEST_DIRNAME/../_orch/CLAUDE.md"
  grep -Eiq 'nesting a team|memory permitting' "$BATS_TEST_DIRNAME/../_orch/CLAUDE.md"
}
