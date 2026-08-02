#!/usr/bin/env bats
# Hermetic tests for the flock-based worker-status writer (issue #11):
# _orch/lib.sh's write_worker_status()/update_worker_status(), plus structural
# checks that report.sh/spawn.sh route every status write through them instead
# of doing their own unlocked `jq > tmp && mv`. No tmux window and no `claude`
# process is ever launched.

setup() {
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  mkdir -p "$ORCH_ROOT/_orch/state/workers"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/lib.sh"
}

@test "write_worker_status creates a fresh status file" {
  write_worker_status w1 --arg id w1 --arg s spawning '{id:$id, status:$s}'
  [ "$(jq -r '.id' "$WORKERS_DIR/w1.json")" = w1 ]
  [ "$(jq -r '.status' "$WORKERS_DIR/w1.json")" = spawning ]
}

@test "write_worker_status overwrites an existing status file" {
  echo '{"id":"w1","status":"old","stale":true}' > "$WORKERS_DIR/w1.json"
  write_worker_status w1 --arg id w1 --arg s new '{id:$id, status:$s}'
  [ "$(jq -r '.status' "$WORKERS_DIR/w1.json")" = new ]
  [ "$(jq 'has("stale")' "$WORKERS_DIR/w1.json")" = false ]
}

@test "update_worker_status merges onto an existing file, preserving other fields" {
  jq -n '{id:"w1", status:"working", model:"sonnet", task:"do the thing"}' > "$WORKERS_DIR/w1.json"
  update_worker_status w1 --arg s done --arg t "2026-01-01T00:00:00Z" '.status=$s | .updated=$t'
  [ "$(jq -r '.status' "$WORKERS_DIR/w1.json")" = done ]
  [ "$(jq -r '.model' "$WORKERS_DIR/w1.json")" = sonnet ]
  [ "$(jq -r '.task' "$WORKERS_DIR/w1.json")" = "do the thing" ]
}

@test "update_worker_status creates the file from {} when it doesn't exist yet" {
  [ ! -e "$WORKERS_DIR/w1.json" ]
  update_worker_status w1 --arg id w1 --arg s needs-input '.id=(.id // $id) | .status=$s'
  [ "$(jq -r '.id' "$WORKERS_DIR/w1.json")" = w1 ]
  [ "$(jq -r '.status' "$WORKERS_DIR/w1.json")" = needs-input ]
}

@test "concurrent update_worker_status calls never corrupt or lose a write" {
  jq -n '{id:"w1", status:"working"}' > "$WORKERS_DIR/w1.json"
  local_n=20
  for i in $(seq 1 "$local_n"); do
    ( update_worker_status w1 --arg t "$i" '.updated=$t' ) &
  done
  wait
  # File must still be valid JSON with all expected top-level keys intact —
  # an unlocked writer would leave a truncated/interleaved tmp write behind.
  run jq -e '.id == "w1" and (.updated | type == "string")' "$WORKERS_DIR/w1.json"
  [ "$status" -eq 0 ]
}

@test "report.sh and spawn.sh route status writes through the shared locked helpers" {
  grep -Fq 'update_worker_status' "$BATS_TEST_DIRNAME/../_orch/report.sh"
  grep -Fq 'write_worker_status' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  grep -Fq 'update_worker_status' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  # No leftover unlocked `jq ... > tmp && mv` writes to a worker status file.
  ! grep -E '\$WORKERS_DIR/\$id\.json\.tmp' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  ! grep -E '"\$f\.tmp".*mv "\$f\.tmp"' "$BATS_TEST_DIRNAME/../_orch/report.sh"
}

@test "report.sh writes a status update for a worker that has no status file yet" {
  "$BATS_TEST_DIRNAME/../_orch/report.sh" w9 done
  [ "$(jq -r '.status' "$WORKERS_DIR/w9.json")" = done ]
  [ "$(jq -r '.id' "$WORKERS_DIR/w9.json")" = w9 ]
}
