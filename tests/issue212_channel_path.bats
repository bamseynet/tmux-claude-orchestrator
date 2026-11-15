#!/usr/bin/env bats
# Issue #212: opt-in channel delivery path selection in heartbeat_main().
# Per event the heartbeat picks ONE path: the channel path (append to the
# per-claude-pid outbox the channel server tails; NOTHING typed into the pane)
# only when delivery.channel is on AND a fresh liveness file matches the
# master's claude pid AND loaded=true; otherwise today's tmux injection.
# tmux is stubbed; the "master claude" is a real throwaway process whose argv0
# contains "claude" so pid discovery is exercised for real.

# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  unset SESSION_NAME
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  export SESSION_NAME="orch"

  # Fake master: pane_pid is a shell-ish parent; the claude process is its child.
  bash -c 'exec -a claude-fake sleep 300' &
  FAKE_CLAUDE_PID=$!
  FAKE_PANE_PID="$FAKE_CLAUDE_PID"   # pane_pid itself is the claude process
  export FAKE_PANE_PID
  printf '%s\n' "$FAKE_PANE_PID" > "$BATS_TEST_TMPDIR/panepid"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) printf '%s\n' "$SESSION_NAME" ;;
  capture-pane) printf '❯ ' ;;
  display-message) cat "$BATS_TEST_TMPDIR/panepid" ;;
  load-buffer)  cat > /dev/null ;;
  show-buffer)  exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export ORCH_WINDOW="orchestrator"
  mkdir -p "$ORCH_ROOT/_orch"
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0
      | .delivery.channel = true' \
    "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../_orch/heartbeat.sh"
  OUTBOX="$STATE_DIR/channel-outbox-$FAKE_CLAUDE_PID.jsonl"
}

teardown() {
  touch "$STATE_DIR/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
  [ -n "${FAKE_CLAUDE_PID:-}" ] && kill "$FAKE_CLAUDE_PID" 2>/dev/null || true
}

wait_for() { for _ in $(seq 1 100); do "$@" && return 0; sleep 0.02; done; return 1; }

# <ppid> <loaded:true|false> <age_s>
liveness() {
  mkdir -p "$STATE_DIR"
  jq -n --argjson p "$1" --argjson l "$2" --argjson ts "$(( $(date +%s) - $3 ))" \
    '{pid:99999, ppid:$p, started:$ts, loaded:$l, ts:$ts}' > "$STATE_DIR/channel-$1.json"
}

run_one_event() { # <event-json>
  heartbeat_main &
  HB_PID=$!
  wait_for grep -q 'heartbeat start' "$LOG"
  printf '%s\n' "$1" >> "$INBOX"
  wait_for sh -c "grep -q 'via channel\|woke master' '$LOG'"
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true
}

assert_tmux_path() {
  grep -q 'paste-buffer' "$CALLS"
  [ ! -s "$OUTBOX" ]
}

@test "channel path: fresh matching loaded liveness file -> outbox only, nothing typed into the pane" {
  liveness "$FAKE_CLAUDE_PID" true 0
  run_one_event '{"id":"w1","event":"turn-end"}'
  grep -q '"id":"w1"' "$OUTBOX"
  grep -q 'via channel' "$LOG"
  refute_grep_in_existing 'paste-buffer' "$CALLS"
  refute_grep_in_existing 'send-keys' "$CALLS"
  # inbox drained: event is not left to be re-delivered
  refute_grep '"id":"w1"' "$INBOX"
}

@test "channel path: exactly one outbox line per event (no double delivery)" {
  liveness "$FAKE_CLAUDE_PID" true 0
  run_one_event '{"id":"w1","event":"turn-end"}'
  [ "$(grep -c '"id":"w1"' "$OUTBOX")" -eq 1 ]
  refute_grep_in_existing 'woke master' "$LOG"
}

@test "fallback: liveness file missing -> tmux injection" {
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: liveness file stale -> tmux injection" {
  liveness "$FAKE_CLAUDE_PID" true 600
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: liveness file for a different ppid -> tmux injection" {
  liveness 1 true 0
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: loaded=false (server spawned without the dev flag) -> tmux injection" {
  liveness "$FAKE_CLAUDE_PID" false 0
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: delivery.channel off (default) -> tmux injection even with a fresh loaded file" {
  jq '.delivery.channel = false' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/c" && mv "$ORCH_ROOT/c" "$ORCH_ROOT/_orch/config.json"
  liveness "$FAKE_CLAUDE_PID" true 0
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: file named for the master pid but whose recorded ppid differs -> tmux injection" {
  liveness "$FAKE_CLAUDE_PID" true 0
  jq '.ppid = 1' "$STATE_DIR/channel-$FAKE_CLAUDE_PID.json" > "$STATE_DIR/x" && mv "$STATE_DIR/x" "$STATE_DIR/channel-$FAKE_CLAUDE_PID.json"
  run_one_event '{"id":"w2","event":"turn-end"}'
  assert_tmux_path
}

@test "fallback: master pane has no claude process -> tmux injection" {
  liveness "$FAKE_CLAUDE_PID" true 0
  bash -c 'exec -a plainshell sleep 300' & other=$!
  printf '%s\n' "$other" > "$BATS_TEST_TMPDIR/panepid"
  liveness "$other" true 0
  run_one_event '{"id":"w2","event":"turn-end"}'
  kill "$other" 2>/dev/null || true
  assert_tmux_path
}

@test "default config ships delivery.channel=false" {
  run jq -r '.delivery.channel' "$BATS_TEST_DIRNAME/../_orch/config.json"
  [ "$output" = "false" ]
}

@test "env ORCH_DELIVERY_CHANNEL=1 enables the channel path when config is off" {
  jq '.delivery.channel = false' "$ORCH_ROOT/_orch/config.json" > "$ORCH_ROOT/c" && mv "$ORCH_ROOT/c" "$ORCH_ROOT/_orch/config.json"
  liveness "$FAKE_CLAUDE_PID" true 0
  ORCH_DELIVERY_CHANNEL=1 run_one_event '{"id":"w3","event":"turn-end"}'
  grep -q '"id":"w3"' "$OUTBOX"
  refute_grep_in_existing 'paste-buffer' "$CALLS"
}

@test "env ORCH_DELIVERY_CHANNEL=0 disables the channel path when config is on" {
  liveness "$FAKE_CLAUDE_PID" true 0
  ORCH_DELIVERY_CHANNEL=0 run_one_event '{"id":"w3","event":"turn-end"}'
  assert_tmux_path
}

@test "channel path: outbox lines carry the master claude pid and the event text" {
  liveness "$FAKE_CLAUDE_PID" true 0
  run_one_event '{"id":"w4","event":"worker-done"}'
  run jq -r '[.ppid, .event, .id] | @tsv' "$OUTBOX"
  [ "$output" = "$(printf '%s\t%s\t%s' "$FAKE_CLAUDE_PID" worker-done w4)" ]
}

# --- orphaned outbox replay: no event is lost when the master claude (or its
# server) dies after the heartbeat drained the inbox into its outbox -----------

# <pid> <id>... -- outbox lines exactly as channel_deliver writes them
orphan_outbox() {
  local p="$1"; shift; mkdir -p "$STATE_DIR"
  for id in "$@"; do
    jq -nc --argjson p "$p" --arg id "$id" \
      '{ppid:$p, id:$id, event:"turn-end", ts:"", text:({id:$id, event:"turn-end"}|tojson)}'
  done >> "$STATE_DIR/channel-outbox-$p.jsonl"
}

@test "replay: orphaned outbox (no liveness file) requeues only lines past the cursor, then removes it" {
  orphan_outbox 4242 sent1 lost1 lost2
  head -1 "$STATE_DIR/channel-outbox-4242.jsonl" | wc -c | tr -d ' ' > "$STATE_DIR/channel-cursor-4242"
  : > "$INBOX"
  channel_replay_orphans 15
  [ "$(grep -c . "$INBOX")" -eq 2 ]
  [ "$(jq -r .id "$INBOX" | tr '\n' ' ')" = "lost1 lost2 " ]
  refute_grep '"sent1"' "$INBOX"
  [ ! -e "$STATE_DIR/channel-outbox-4242.jsonl" ]
  [ ! -e "$STATE_DIR/channel-cursor-4242" ]
  grep -q 'requeued 2 undelivered channel event' "$LOG"
}

@test "replay: stale liveness file counts as orphaned" {
  orphan_outbox 4242 lost1
  liveness 4242 true 600
  : > "$INBOX"
  channel_replay_orphans 15
  [ "$(jq -r .id "$INBOX")" = "lost1" ]
  [ ! -e "$STATE_DIR/channel-4242.json" ]
}

@test "replay: a fresh liveness file means a live server owns the outbox -- untouched" {
  orphan_outbox 4242 mine1
  liveness 4242 true 0
  : > "$INBOX"
  channel_replay_orphans 15
  [ ! -s "$INBOX" ]
  grep -q '"mine1"' "$STATE_DIR/channel-outbox-4242.jsonl"
}

@test "replay: master restarted (new claude pid, no channel) -> dead pid's undelivered event is delivered via tmux" {
  orphan_outbox 4242 w9
  run_one_event '{"id":"w10","event":"turn-end"}'
  grep -q 'requeued 1 undelivered channel event' "$LOG"
  grep 'woke master with' "$LOG" | grep -q '"w9"'
  [ ! -e "$STATE_DIR/channel-outbox-4242.jsonl" ]
}
