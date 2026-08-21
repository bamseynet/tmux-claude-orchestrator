#!/usr/bin/env bats
# Hermetic tests for issue #122: collapse the heartbeat inject to one terse
# line, silent when nothing actionable. summarize_events() (heartbeat.sh)
# turns a drained batch of raw JSON event lines into a single terse summary
# line, honoring `heartbeat.inject_denylist` (config.json) as a DENYLIST —
# never an allowlist, so a brand-new/unknown event type always surfaces
# unless someone explicitly denylists it.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/config.json" "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
}

@test "a batch of only subagent-done events produces no summary (silence)" {
  events='{"id":"w1","event":"subagent-done","ts":"t1"}
{"id":"w1","event":"subagent-done","ts":"t2"}'
  run summarize_events "$events"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a batch with subagent-done + done summarizes, mentioning done but not subagent-done" {
  events='{"id":"w1","event":"subagent-done","ts":"t1"}
{"id":"w2","event":"done","ts":"t2"}'
  run summarize_events "$events"
  [ "$status" -eq 0 ]
  [[ "$output" == *"w2 done"* ]]
  [[ "$output" != *"subagent-done"* ]]
}

@test "repeated (id,event) pairs collapse with a count" {
  events='{"id":"w1","event":"needs-input","ts":"t1"}
{"id":"w1","event":"needs-input","ts":"t2"}
{"id":"w1","event":"needs-input","ts":"t3"}'
  run summarize_events "$events"
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1 needs-input x3"* ]]
}

@test "an unknown/future event type is always summarized (denylist, not allowlist)" {
  events='{"id":"w9","event":"totally-new-event-type","ts":"t1"}'
  run summarize_events "$events"
  [ "$status" -eq 0 ]
  [[ "$output" == *"w9 totally-new-event-type"* ]]
}

@test "inject_denylist: [] reproduces today's full-fidelity behaviour (nothing dropped)" {
  jq '.heartbeat.inject_denylist = []' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/_orch/config.json.tmp"
  mv "$ORCH_ROOT/_orch/config.json.tmp" "$ORCH_ROOT/_orch/config.json"

  events='{"id":"w1","event":"subagent-done","ts":"t1"}'
  run summarize_events "$events"
  [ "$status" -eq 0 ]
  [[ "$output" == *"w1 subagent-done"* ]]
}

@test "the terse line is a single line with no JSON in it" {
  events='{"id":"w1","event":"done","ts":"t1"}
{"id":"w2","event":"needs-input","ts":"t2"}'
  run summarize_events "$events"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
  [[ "$output" != *'{'* ]]
}
