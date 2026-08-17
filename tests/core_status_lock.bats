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

@test "with_lock uses flock when it is present on PATH" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed on this host"
  local lock="$BATS_TEST_TMPDIR/some.lock"
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; with_lock "'"$lock"'"'
  [ "$status" -eq 0 ]
  # flock path never creates an mkdir lock dir.
  [ ! -e "$lock.d" ]
}

# --- macOS fallback path (issue #76): shadow flock with a PATH that genuinely has
# no flock binary on it -- not a fake `flock` script (that would still satisfy
# `command -v flock`), a curated PATH built only from symlinks to the handful of
# external tools with_lock/write_worker_status/update_worker_status actually call.
# This makes `command -v flock` fail exactly the way it would on a real macOS host,
# so the mkdir-based fallback in lib.sh is genuinely exercised on Linux CI.
_no_flock_path() {
  local fakebin="$BATS_TEST_TMPDIR/no-flock-bin"
  mkdir -p "$fakebin"
  local tool real
  for tool in jq mv date stat kill sleep rm cat printf mkdir env bash sh dirname seq wc; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$fakebin/$tool"
  done
  echo "$fakebin"
}

@test "fallback: with_lock falls back to mkdir-mutex when flock is absent from PATH" {
  local fakebin; fakebin="$(_no_flock_path)"
  PATH="$fakebin" run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    ! command -v flock >/dev/null 2>&1 || { echo "flock still on PATH"; exit 1; }
    lock="'"$BATS_TEST_TMPDIR"'/fallback.lock"
    ( with_lock "$lock" || exit 1 )
    [ -e "$lock.d" ] && { echo "lock dir not released"; exit 1; }
    echo OK
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "fallback: write_worker_status/update_worker_status work without flock on PATH" {
  local fakebin; fakebin="$(_no_flock_path)"
  PATH="$fakebin" ORCH_ROOT="$ORCH_ROOT" run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    write_worker_status w1 --arg id w1 --arg s spawning "{id:\$id, status:\$s}"
    update_worker_status w1 --arg s working ".status=\$s"
    jq -e ".id==\"w1\" and .status==\"working\"" "$WORKERS_DIR/w1.json" >/dev/null
  '
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$WORKERS_DIR/w1.json")" = working ]
}

@test "fallback: a stale mkdir lock (dead holder pid) is reclaimed, not waited out" {
  local fakebin; fakebin="$(_no_flock_path)"
  local lock="$BATS_TEST_TMPDIR/stale.lock"
  mkdir -p "$lock.d"
  # A pid that is guaranteed not to be alive.
  echo 999999 > "$lock.d/pid"
  PATH="$fakebin" ORCH_LOCK_TIMEOUT=5 run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    ( with_lock "'"$lock"'" || exit 1 )
    echo OK
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "fallback: a genuinely held lock times out instead of hanging forever" {
  local fakebin; fakebin="$(_no_flock_path)"
  local lock="$BATS_TEST_TMPDIR/held.lock"
  mkdir -p "$lock.d"
  echo $$ > "$lock.d/pid"
  PATH="$fakebin" ORCH_LOCK_TIMEOUT=1 run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"
    with_lock "'"$lock"'"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

@test "concurrent write_worker_status calls never corrupt or lose a write (fresh files)" {
  for i in $(seq 1 15); do
    ( write_worker_status "w-$i" --arg id "w-$i" --arg s spawning '{id:$id, status:$s}' ) &
  done
  wait
  for i in $(seq 1 15); do
    run jq -e --arg id "w-$i" '.id == $id and .status == "spawning"' "$WORKERS_DIR/w-$i.json"
    [ "$status" -eq 0 ]
  done
}

@test "concurrent update_worker_status calls on distinct ids never interleave into the wrong file" {
  for i in $(seq 1 10); do
    ( update_worker_status "u-$i" --arg id "u-$i" --arg s working '.id=(.id // $id) | .status=$s' ) &
  done
  wait
  for i in $(seq 1 10); do
    run jq -e --arg id "u-$i" '.id == $id and .status == "working"' "$WORKERS_DIR/u-$i.json"
    [ "$status" -eq 0 ]
  done
}
