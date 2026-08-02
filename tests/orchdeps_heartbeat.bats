#!/usr/bin/env bats
# Hermetic tests for issue #22 (task dependencies): heartbeat.sh's
# queue_pop_ready() / drain_queue_if_room() must hold a queued spawn whose
# `after` dependency has not reached "done" yet, skip over it in favor of a
# later, ready item, and drain it as soon as the dependency completes.
#
# heartbeat.sh sources lib.sh and defines its helpers at source-time; the loop
# itself only runs when executed directly (BASH_SOURCE guard), so sourcing here
# never starts it, touches tmux, or launches `claude`.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
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

@test "queue_pop_ready returns non-zero on an empty/missing queue" {
  rm -f "$QUEUE"
  run queue_pop_ready
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "queue_pop_ready drains a dependency-less item immediately (FIFO, unchanged)" {
  queue_push '{"id":"a"}'
  queue_push '{"id":"b"}'
  run queue_pop_ready
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"a"'* ]]
  run queue_pop_ready
  [[ "$output" == *'"id":"b"'* ]]
}

@test "queue_pop_ready holds an item whose dependency is not done yet" {
  worker_json w1 working
  queue_push '{"id":"w2","after":"w1"}'
  run queue_pop_ready
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # queue is left untouched
  run jq -r .id "$QUEUE"
  [ "$output" = "w2" ]
}

@test "queue_pop_ready drains the dependent once its dependency is done" {
  worker_json w1 done
  queue_push '{"id":"w2","after":"w1"}'
  run queue_pop_ready
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"w2"'* ]]
  [ ! -s "$QUEUE" ]
}

@test "queue_pop_ready skips a blocked dependent and drains a later ready item, preserving the blocked one" {
  worker_json w1 working
  queue_push '{"id":"w2","after":"w1"}'  # blocked: w1 not done
  queue_push '{"id":"w3"}'               # no dependency: ready

  run queue_pop_ready
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"w3"'* ]]

  # w2 remains queued, still waiting on w1
  run jq -r .id "$QUEUE"
  [ "$output" = "w2" ]
}

@test "drain_queue_if_room does not launch a dependent whose dependency is unfinished" {
  worker_json w1 working
  queue_push '{"id":"w2","model":"sonnet","task":"t","mode":"","resume":"","allow_csv":"","after":"w1"}'
  # spawn.sh is not stubbed: if drain attempted to launch, this would fail loudly
  # since there is no real spawn.sh invocation happening in the background here;
  # instead assert the queue is untouched and nothing was popped.
  drain_queue_if_room
  run jq -r .id "$QUEUE"
  [ "$output" = "w2" ]
}

@test "drain_queue_if_room launches the dependent once its dependency reports done" {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/spawn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/spawn_args.txt"
EOF
  chmod +x "$STUBBIN/spawn.sh"
  # heartbeat.sh calls "\$here/spawn.sh" (script-relative), so point `here` at
  # our stub directory instead of the real _orch/spawn.sh.
  here="$STUBBIN"

  worker_json w1 done
  queue_push '{"id":"w2","model":"sonnet","task":"do it","mode":"","resume":"","allow_csv":"","after":"w1"}'

  drain_queue_if_room
  # background spawn; give the subshell a moment to write its args file
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$BATS_TEST_TMPDIR/spawn_args.txt" ] && break
    sleep 0.1
  done
  [ -s "$BATS_TEST_TMPDIR/spawn_args.txt" ]
  grep -Fq "w2" "$BATS_TEST_TMPDIR/spawn_args.txt"
  grep -Fq "sonnet" "$BATS_TEST_TMPDIR/spawn_args.txt"
  [ ! -s "$QUEUE" ]
}
