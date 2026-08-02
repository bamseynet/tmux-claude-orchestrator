#!/usr/bin/env bats
# Hermetic tests for _orch/rehydrate.sh (issue #41): building a concise
# "what's in flight" summary from _orch/state/* so the master can reconstruct
# orchestration state after a compaction or restart, and the locked
# review_log_append() writer it exposes.
#
# rehydrate.sh sources lib.sh and only runs rehydrate_summary when executed
# directly (BASH_SOURCE guard), so sourcing it here exposes the helpers
# without touching tmux/claude. ORCH_ROOT is redirected to a temp dir so the
# real repo state is never touched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/rehydrate.sh"
}

@test "rehydrate_summary reports (none)/(empty)/(none recorded yet) on a fresh state dir" {
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"(none)"* ]]
  [[ "$output" == *"(empty)"* ]]
  [[ "$output" == *"(none recorded yet)"* ]]
  [[ "$output" == *"(no master-notes.md yet)"* ]]
}

@test "rehydrate_summary lists every worker status file" {
  jq -n '{id:"w1", status:"working", model:"sonnet", task:"build the thing", updated:"2026-01-01T00:00:00Z"}' > "$WORKERS_DIR/w1.json"
  jq -n '{id:"w2", status:"needs-input", model:"opus", task:"research X", updated:"2026-01-01T00:01:00Z"}' > "$WORKERS_DIR/w2.json"
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1: status=working"* ]]
  [[ "$output" == *"w2: status=needs-input"* ]]
}

@test "rehydrate_summary truncates a long task string" {
  local long_task
  long_task="$(printf 'x%.0s' $(seq 1 200))"
  jq -n --arg t "$long_task" '{id:"w1", status:"working", model:"sonnet", task:$t}' > "$WORKERS_DIR/w1.json"
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"…"* ]]
  # The full 200-char task string must not appear verbatim.
  [[ "$output" != *"$long_task"* ]]
}

@test "rehydrate_summary lists queued spawns from queue.jsonl" {
  printf '%s\n' '{"id":"w3","model":"haiku","task":"lint everything"}' >> "$QUEUE"
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"w3: model=haiku task=lint everything"* ]]
}

@test "review_log_append writes a well-formed line and rehydrate_summary surfaces it" {
  review_log_append w1 orch/w1 approved "tests green, diff sane" abc123
  [ -s "$REVIEW_LOG" ]
  run jq -e '.worker_id == "w1" and .verdict == "approved" and .commit_sha == "abc123"' "$REVIEW_LOG"
  [ "$status" -eq 0 ]

  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1 approved: tests green, diff sane"* ]]
}

@test "review_log_append only shows the most recent 10 entries in the summary" {
  for i in $(seq 1 12); do
    review_log_append "w$i" "orch/w$i" approved "reason $i"
  done
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" != *"w1 approved"* ]]
  [[ "$output" != *"w2 approved"* ]]
  [[ "$output" == *"w12 approved"* ]]
}

@test "concurrent review_log_append calls never interleave or corrupt lines" {
  for i in $(seq 1 20); do
    ( review_log_append "w$i" "orch/w$i" approved "concurrent $i" ) &
  done
  wait
  [ "$(wc -l < "$REVIEW_LOG")" -eq 20 ]
  # Every line must independently parse as valid JSON — an unlocked writer
  # could interleave two concurrent appends into one broken line.
  while IFS= read -r line; do
    echo "$line" | jq -e . >/dev/null
  done < "$REVIEW_LOG"
}

@test "rehydrate_summary surfaces master-notes.md content verbatim" {
  printf 'Active priority: ship #41. w1 is mid-review.\n' > "$MASTER_NOTES"
  run rehydrate_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active priority: ship #41. w1 is mid-review."* ]]
}

@test "running rehydrate.sh directly prints the summary without starting any loop" {
  jq -n '{id:"w1", status:"working"}' > "$WORKERS_DIR/w1.json"
  run "$BATS_TEST_DIRNAME/../_orch/rehydrate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[rehydrate]"* ]]
  [[ "$output" == *"w1: status=working"* ]]
}
