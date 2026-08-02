#!/usr/bin/env bats
# Hermetic tests for _orch/report.sh: the worker hook that appends an inbox event
# and creates/updates the worker's status file. It must always exit 0 (it runs from
# a Stop/Notification/SubagentStop hook and must never block the worker's turn).
# ORCH_ROOT is redirected to a temp dir so the real repo state is never touched;
# no tmux window and no `claude` process is ever launched.

REPORT="$BATS_TEST_DIRNAME/../_orch/report.sh"

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch"
}

@test "report.sh creates a new status file and appends an inbox line when none existed" {
  run "$REPORT" w1 done
  [ "$status" -eq 0 ]

  f="$ORCH_ROOT/_orch/state/workers/w1.json"
  [ -f "$f" ]
  run jq -r .id "$f"; [ "$output" = "w1" ]
  run jq -r .status "$f"; [ "$output" = "done" ]

  run cat "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [[ "$output" == *'"id":"w1"'* ]]
  [[ "$output" == *'"event":"done"'* ]]
}

@test "report.sh updates an existing status file's status/updated, preserving other fields" {
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  jq -n '{id:"w2", status:"working", model:"sonnet", task:"do the thing", updated:"then"}' \
    > "$ORCH_ROOT/_orch/state/workers/w2.json"

  run "$REPORT" w2 needs-input
  [ "$status" -eq 0 ]

  f="$ORCH_ROOT/_orch/state/workers/w2.json"
  run jq -r .status "$f"; [ "$output" = "needs-input" ]
  run jq -r .model "$f"; [ "$output" = "sonnet" ]
  run jq -r .task "$f"; [ "$output" = "do the thing" ]
  run jq -r .updated "$f"; [ "$output" != "then" ]
}

@test "report.sh defaults id to ORCH_WORKER_ID and event to 'update' when omitted" {
  export ORCH_WORKER_ID=w3
  run "$REPORT"
  [ "$status" -eq 0 ]
  run jq -r .id "$ORCH_ROOT/_orch/state/workers/w3.json"
  [ "$output" = "w3" ]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w3.json"
  [ "$output" = "update" ]
}

@test "report.sh defaults id to 'unknown' when neither an arg nor ORCH_WORKER_ID is set" {
  unset ORCH_WORKER_ID
  run "$REPORT"
  [ "$status" -eq 0 ]
  [ -f "$ORCH_ROOT/_orch/state/workers/unknown.json" ]
}

@test "report.sh appends multiple events without clobbering earlier inbox lines" {
  run "$REPORT" w4 spawning
  run "$REPORT" w4 working
  run "$REPORT" w4 done

  run wc -l < "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [ "$output" -eq 3 ]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w4.json"
  [ "$output" = "done" ]
}

@test "report.sh exits 0 even when the status file is unwritable (never blocks the worker)" {
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # Make the target path itself a directory so the jq/mv update path fails.
  mkdir -p "$ORCH_ROOT/_orch/state/workers/w5.json"
  run "$REPORT" w5 done
  [ "$status" -eq 0 ]
}
