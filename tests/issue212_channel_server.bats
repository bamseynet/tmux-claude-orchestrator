#!/usr/bin/env bats
# Issue #212: the channel server (_orch/channel/server.mjs). Needs node and the
# pinned SDK (`npm ci` in _orch/channel); skipped with an explicit reason when
# either is missing so a missing toolchain is never a silent pass.

SERVER="$BATS_TEST_DIRNAME/../_orch/channel/server.mjs"

setup() {
  command -v node >/dev/null || skip "node not installed (channel server tests need node >= 18)"
  [ -d "$BATS_TEST_DIRNAME/../_orch/channel/node_modules/@modelcontextprotocol/sdk" ] \
    || skip "channel deps not installed (run: npm ci --prefix _orch/channel)"
  ST="$BATS_TEST_TMPDIR/state"; mkdir -p "$ST"
  OUT="$BATS_TEST_TMPDIR/out.jsonl"; : > "$OUT"
}

teardown() {
  exec 8>&- 2>/dev/null || true
  [ -n "${WRAP_PID:-}" ] && kill "$WRAP_PID" 2>/dev/null || true
}

wait_for() { for _ in $(seq 1 150); do "$@" && return 0; sleep 0.05; done; return 1; }

# <flagged:1|0> -- the wrapper bash is the server's parent ("claude"); its argv
# carries the dev-channels flag only when flagged=1. stdin stays open via sleep.
start_server() {
  local extra=""
  [ "$1" = 1 ] && extra="--dangerously-load-development-channels server:orch"
  # stdin is a fifo whose write end (fd 8) this shell holds open; teardown closes it,
  # the server sees EOF and exits. bash -c ...; true stops bash exec-ing node, so the
  # wrapper stays the server's parent.
  FIFO="$BATS_TEST_TMPDIR/stdin.fifo"; mkfifo "$FIFO"; exec 8<>"$FIFO"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.325"}}}' \
                 '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&8
  ORCH_STATE_DIR="$ST" bash -c 'node "$1"; true' fakeclaude "$SERVER" $extra < "$FIFO" > "$OUT" 2>/dev/null 3>&- 8>&- &
  FEED_PID=$!
  wait_for sh -c "ls '$ST'/channel-[0-9]*.json >/dev/null 2>&1"
  LIVE="$(ls "$ST"/channel-[0-9]*.json | head -1)"
  PPID_SRV="$(jq -r .ppid "$LIVE")"
  WRAP_PID="$PPID_SRV"
}

notifs() { jq -c 'select(.method=="notifications/claude/channel")' "$OUT" 2>/dev/null; }

@test "server: liveness file records ppid, pid, and loaded=true when parent argv has the flag" {
  start_server 1
  run jq -r '[.loaded, (.ppid|type), (.ts|type)] | @tsv' "$LIVE"
  [ "$output" = "$(printf 'true\tnumber\tnumber')" ]
}

@test "server: loaded=false when parent argv lacks the flag, and it does not consume the outbox" {
  start_server 0
  [ "$(jq -r .loaded "$LIVE")" = "false" ]
  printf '%s\n' "{\"ppid\":$PPID_SRV,\"id\":\"a\",\"event\":\"worker-done\",\"ts\":\"1\",\"text\":\"hello\"}" > "$ST/channel-outbox-$PPID_SRV.jsonl"
  sleep 1
  [ -z "$(notifs)" ]
}

@test "server: emits one channel notification per outbox line with content and meta" {
  start_server 1
  printf '%s\n' "{\"ppid\":$PPID_SRV,\"id\":\"e1\",\"event\":\"worker-done\",\"ts\":\"77\",\"text\":\"hello world\"}" >> "$ST/channel-outbox-$PPID_SRV.jsonl"
  wait_for sh -c "[ -n \"\$(jq -c 'select(.method==\"notifications/claude/channel\")' '$OUT' 2>/dev/null)\" ]"
  [ "$(notifs | wc -l)" -eq 1 ]
  run bash -c "jq -r '[.params.content, .params.meta.id, .params.meta.event, .params.meta.ts] | @tsv' <<<'$(notifs)'"
  [ "$output" = "$(printf 'hello world\te1\tworker-done\t77')" ]
}

@test "server: ignores lines stamped for another ppid" {
  start_server 1
  printf '%s\n' '{"ppid":1,"id":"x","event":"e","ts":"1","text":"not mine"}' \
    "{\"ppid\":$PPID_SRV,\"id\":\"y\",\"event\":\"e\",\"ts\":\"2\",\"text\":\"mine\"}" >> "$ST/channel-outbox-$PPID_SRV.jsonl"
  wait_for sh -c "[ -n \"\$(jq -c 'select(.method==\"notifications/claude/channel\")' '$OUT' 2>/dev/null)\" ]"
  sleep 0.5
  [ "$(notifs | wc -l)" -eq 1 ]
  [ "$(notifs | jq -r .params.content)" = "mine" ]
}

@test "server: persists a cursor so a restarted server does not re-emit delivered lines" {
  start_server 1
  printf '%s\n' "{\"ppid\":$PPID_SRV,\"id\":\"e1\",\"event\":\"e\",\"ts\":\"1\",\"text\":\"one\"}" >> "$ST/channel-outbox-$PPID_SRV.jsonl"
  wait_for sh -c "[ -n \"\$(jq -c 'select(.method==\"notifications/claude/channel\")' '$OUT' 2>/dev/null)\" ]"
  wait_for test -s "$ST/channel-cursor-$PPID_SRV"
  [ "$(cat "$ST/channel-cursor-$PPID_SRV")" -eq "$(wc -c < "$ST/channel-outbox-$PPID_SRV.jsonl")" ]
}

@test "server: a torn (partial) line is held until its newline arrives" {
  start_server 1
  o="$ST/channel-outbox-$PPID_SRV.jsonl"
  printf '%s' "{\"ppid\":$PPID_SRV,\"id\":\"p\",\"event\":\"e\",\"ts\":\"1\",\"te" >> "$o"
  sleep 1
  [ -z "$(notifs)" ]
  printf '%s\n' 'xt":"whole"}' >> "$o"
  wait_for sh -c "[ -n \"\$(jq -c 'select(.method==\"notifications/claude/channel\")' '$OUT' 2>/dev/null)\" ]"
  [ "$(notifs | jq -r .params.content)" = "whole" ]
}

@test "server: declares no tools and the claude/channel capability" {
  start_server 1
  wait_for sh -c "grep -q '\"id\":1' '$OUT'"
  run jq -c 'select(.id==1) | .result.capabilities' "$OUT"
  [[ "$output" == *'"claude/channel"'* ]]
  [[ "$output" != *'"tools"'* ]]
}
