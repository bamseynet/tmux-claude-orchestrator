#!/usr/bin/env bats
# Hermetic tests for issue #160 (#158 part B): heartbeat.sh resets the master's
# context (checkpoint prompt -> /clear) when master-context.json says it is too
# full. tmux is stubbed; HOME/ORCH_ROOT live under $BATS_TEST_TMPDIR; nothing
# here ever types into a real pane.

REPO="$BATS_TEST_DIRNAME/.."
source "$BATS_TEST_DIRNAME/helpers/refute.bash"
source "$BATS_TEST_DIRNAME/helpers/timeout_scale.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  PANE_TEXT_FILE="$BATS_TEST_TMPDIR/pane_text"
  DRAFT_PANE_FILE="$BATS_TEST_TMPDIR/pane_draft"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  : > "$CALLS"
  printf '❯ \n? for shortcuts' > "$PANE_TEXT_FILE"
  printf '❯ half typed operator text\n? for shortcuts' > "$DRAFT_PANE_FILE"
  export SESSION_NAME="orch"
  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export ORCH_WINDOW="orchestrator"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$ORCH_ROOT/_orch" "$HOME"
  NOTES="$ORCH_ROOT/_orch/state/master-notes.md"
  # Knobs the tmux stub reads on a load-buffer carrying the checkpoint prompt.
  export TOUCH_FLAG="$BATS_TEST_TMPDIR/touch_notes_on_checkpoint"
  export DRAFT_FLAG="$BATS_TEST_TMPDIR/draft_after_checkpoint"
  export NO_CLEAR_FLAG="$BATS_TEST_TMPDIR/clear_does_not_take"
  export NOTES CALLS PANE_TEXT_FILE DRAFT_PANE_FILE

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$CALLS"
case "${1:-}" in
  list-sessions) printf '%s\n' "$SESSION_NAME" ;;
  capture-pane)  cat "$PANE_TEXT_FILE" ;;
  load-buffer)
    body="$(cat)"
    printf 'PASTE<<%s>>\n' "$body" >> "$CALLS"
    case "$body" in
      *master-notes.md*)
        [ -e "$TOUCH_FLAG" ] && touch "$NOTES"
        [ -e "$DRAFT_FLAG" ] && cp "$DRAFT_PANE_FILE" "$PANE_TEXT_FILE"
        ;;
      /clear)  # what the SessionStart hook does on a real /clear
        [ -e "$NO_CLEAR_FLAG" ] || printf '{"session_id":"cleared-%s","source":"clear"}\n' "$$" > "$(dirname "$NOTES")/master-session.json"
        ;;
    esac ;;
  show-buffer)   exit 1 ;;
esac
exit 0
EOF
  chmod +x "$STUBBIN/tmux"
  PATH="$STUBBIN:$PATH"

  jq --argjson t "$(scaled_timeout 2)" \
     '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0
      | .master_context = {checkpoint_timeout_s: $t}' \
    "$REPO/_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$REPO/_orch/heartbeat.sh"
  mkdir -p "$STATE_DIR"
  printf 'old notes\n' > "$NOTES"
  touch -d '2000-01-01' "$NOTES"
}

teardown() {
  touch "$STATE_DIR/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
}

wait_for() { # <predicate...> -- bounded poll, 20ms ticks, scaled
  local n
  n=$(scaled_timeout 400)
  for _ in $(seq 1 "$n"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.02
  done
  return 1
}

start_hb() {
  heartbeat_main &
  HB_PID=$!
  wait_for grep -q 'heartbeat start' "$LOG"
}

stop_hb() {
  touch "$STATE_DIR/.stop"
  wait "$HB_PID" 2>/dev/null || true
}

# ctx <pct> <tokens> <session_id>; sess <session_id>
ctx()  { jq -nc --argjson p "$1" --argjson t "$2" --arg s "$3" --argjson w "${4:-1000000}" '{pct:$p,tokens:$t,window:$w,session_id:$s,ts:"2026-10-25T00:00:00Z"}' > "$STATE_DIR/master-context.json"; }
sess() { jq -nc --arg s "$1" '{session_id:$s,source:"startup",ts:"2026-10-25T00:00:00Z"}' > "$STATE_DIR/master-session.json"; }

NOW=1000000
# due <ctx> <sess> <last> <pct> <fraction> <cooldown> [enabled]
due() { master_reset_due "$1" "$2" "$NOW" "$3" "$4" "$5" "$6" "${7:-}"; }
C_OVER_PCT='{"pct":75,"tokens":100,"window":1000000,"session_id":"s1"}'
C_OVER_TOK='{"pct":10,"tokens":400000,"window":1000000,"session_id":"s1"}'
C_UNDER='{"pct":10,"tokens":1000,"window":1000000,"session_id":"s1"}'
S1='{"session_id":"s1"}'

# ---------------------------------------------------------------- B1
@test "B1: due when only pct is over" {
  due "$C_OVER_PCT" "$S1" '{}' 60 0.35 1800
}
@test "B1: due when only tokens are over" {
  due "$C_OVER_TOK" "$S1" '{}' 60 0.35 1800
}
@test "B1: not due when both are under" {
  run due "$C_UNDER" "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
}
@test "B1: not due on a stale pre-clear reading (ctx session != current session)" {
  run due "$C_OVER_PCT" '{"session_id":"s2"}' '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
}
@test "B1: not due within cooldown, due once it has elapsed" {
  run due "$C_OVER_PCT" "$S1" "{\"ts\":$((NOW - 100))}" 60 0.35 1800
  [ "$status" -eq 1 ]
  due "$C_OVER_PCT" "$S1" "{\"ts\":$((NOW - 1800))}" 60 0.35 1800
}
@test "B1: not due when master_context.enabled=false" {
  run due "$C_OVER_PCT" "$S1" '{}' 60 0.35 1800 false
  [ "$status" -eq 1 ]
}
@test "B1: not due when backoff=true" {
  run due "$C_OVER_PCT" "$S1" '{"ts":1,"backoff":true}' 60 0.35 1800
  [ "$status" -eq 1 ]
}
@test "B1: defaults apply when the master_context block is absent (empty args)" {
  due '{"pct":61,"tokens":1,"window":1000000,"session_id":"s1"}' "$S1" '' '' '' ''
  due '{"pct":1,"tokens":350000,"window":1000000,"session_id":"s1"}' "$S1" '' '' '' ''
  run due '{"pct":59,"tokens":349999,"window":1000000,"session_id":"s1"}' "$S1" '' '' '' ''
  [ "$status" -eq 1 ]
  run due "$C_OVER_PCT" "$S1" "{\"ts\":$((NOW - 1799))}" '' '' ''
  [ "$status" -eq 1 ]
}
@test "B1: tokens threshold scales with the window (200k vs 1M)" {
  # 80k tokens is 40% of a 200k window (due) but 8% of a 1M window (not due)
  due '{"pct":10,"tokens":80000,"window":200000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  run due '{"pct":10,"tokens":80000,"window":1000000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
  # 69999 of 200k is just under 0.35; 70000 is due
  run due '{"pct":10,"tokens":69999,"window":200000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
  due '{"pct":10,"tokens":70000,"window":200000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  # 350k of 1M is due, 349999 is not
  due '{"pct":10,"tokens":350000,"window":1000000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  run due '{"pct":10,"tokens":349999,"window":1000000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
}
@test "B1: unknown or missing window -> never due, even with huge numbers" {
  run due '{"pct":99,"tokens":900000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
  run due '{"pct":99,"tokens":900000,"window":null,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
  run due '{"pct":99,"tokens":900000,"window":0,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
}
@test "B1: null readings (just after /clear) are not due" {
  run due '{"pct":null,"tokens":null,"session_id":"s1"}' "$S1" '' 60 0.35 1800
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------- B2
@test "B2: over threshold -> checkpoint paste, then /clear, then state + log" {
  touch "$TOUCH_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for test -f "$STATE_DIR/master-reset.json"
  stop_hb

  cp_line="$(grep -n 'PASTE<<.*master-notes.md' "$CALLS" | head -1 | cut -d: -f1)"
  clr_line="$(grep -n 'PASTE<</clear>>' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$cp_line" ]
  [ -n "$clr_line" ]
  [ "$cp_line" -lt "$clr_line" ]
  [ "$(jq -r .old_session_id "$STATE_DIR/master-reset.json")" = "s1" ]
  [ "$(jq .pct "$STATE_DIR/master-reset.json")" = "75" ]
  [ "$(jq .tokens "$STATE_DIR/master-reset.json")" = "400000" ]
  jq -e '.ts | type == "number"' "$STATE_DIR/master-reset.json"
  grep -q 'master context reset (pct=75 tokens=400000)' "$LOG"
  grep -q '"event":"master-reset"' "$STATE_DIR/events.jsonl"
  # cooldown: exactly one reset however many ticks ran
  [ "$(grep -c 'PASTE<</clear>>' "$CALLS")" -eq 1 ]
}

@test "B2: a 200k-window master at 40% tokens (80000) resets; a 1M one at 8% does not" {
  touch "$TOUCH_FLAG"
  ctx 10 80000 s1 1000000; sess s1
  start_hb
  sleep 0.7
  refute_grep 'master-notes.md' "$CALLS"
  ctx 10 80000 s1 200000
  wait_for test -f "$STATE_DIR/master-reset.json"
  stop_hb
  grep -q 'PASTE<</clear>>' "$CALLS"
  grep -q 'master context reset (pct=10 tokens=80000)' "$LOG"
}

@test "B2: under threshold -> master is never touched" {
  touch "$TOUCH_FLAG"
  ctx 10 1000 s1; sess s1
  start_hb
  sleep 0.5
  stop_hb
  refute_grep 'master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
  [ ! -e "$STATE_DIR/master-reset.json" ]
}

# ---------------------------------------------------------------- B3
@test "B3: notes never touched within the timeout -> no /clear, no master-reset.json" {
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'master reset aborted' "$LOG"
  sleep 0.3
  stop_hb
  grep -q 'PASTE<<.*master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
  [ ! -e "$STATE_DIR/master-reset.json" ]
  # retried not every tick: one checkpoint only
  [ "$(grep -c 'PASTE<<.*master-notes.md' "$CALLS")" -eq 1 ]
}

@test "B3: draft appears after the checkpoint -> no /clear, no master-reset.json" {
  touch "$TOUCH_FLAG" "$DRAFT_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'master reset aborted' "$LOG"
  stop_hb
  grep -q 'PASTE<<.*master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
  [ ! -e "$STATE_DIR/master-reset.json" ]
}

@test "B3: draft before the checkpoint -> checkpoint not sent either" {
  cp "$DRAFT_PANE_FILE" "$PANE_TEXT_FILE"
  touch "$TOUCH_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  sleep 1
  stop_hb
  grep -q 'capture-pane' "$CALLS"   # the reset path did look at the pane
  refute_grep 'master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
  [ ! -e "$STATE_DIR/master-reset.json" ]
}

# ---------------------------------------------------------------- B4
@test "B4: a done event in the inbox on the resetting tick is delivered after /clear" {
  touch "$TOUCH_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  # heartbeat_main truncates the inbox at start; land the event mid-reset
  wait_for grep -q 'checkpoint requested' "$LOG"
  printf '{"id":"w7","event":"done","ts":"2026-10-25T00:00:00Z"}\n' >> "$INBOX"
  wait_for grep -q 'woke master with' "$LOG"
  stop_hb
  clr_line="$(grep -n 'PASTE<</clear>>' "$CALLS" | head -1 | cut -d: -f1)"
  wake_line="$(grep -n 'PASTE<<.*Worker events since last check' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$clr_line" ]
  [ -n "$wake_line" ]
  [ "$clr_line" -lt "$wake_line" ]
  grep -q '"id":"w7"' "$CALLS"
}

# ---------------------------------------------------------------- B5
@test "B5: still over threshold after a reset -> backoff set once, never resets again" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  ctx 90 500000 b; sess b
  touch "$TOUCH_FLAG"
  start_hb
  wait_for jq -e '.backoff == true' "$STATE_DIR/master-reset.json"
  sleep 0.5   # several more ticks
  stop_hb
  [ "$(jq .backoff "$STATE_DIR/master-reset.json")" = "true" ]
  [ "$(grep -c 'master context reset loop' "$LOG")" -eq 1 ]
  refute_grep 'master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
}

@test "B5: window unknown on the first post-reset reading -> no backoff (unknown data)" {
  jq -nc '{ts:1,old_session_id:"a"}' > "$STATE_DIR/master-reset.json"
  jq -nc '{pct:90,tokens:900000,window:null,session_id:"b"}' > "$STATE_DIR/master-context.json"; sess b
  start_hb
  sleep 0.5
  stop_hb
  [ "$(jq '.backoff // false' "$STATE_DIR/master-reset.json")" = "false" ]
}

@test "B5: first post-reset reading under threshold -> no backoff, later growth may reset again" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  ctx 12 60000 b; sess b
  start_hb
  sleep 0.5
  stop_hb
  [ "$(jq '.backoff // false' "$STATE_DIR/master-reset.json")" = "false" ]
  # the guard actually ran and judged the reading (not a vacuous no-tick pass)
  [ "$(jq '.verified' "$STATE_DIR/master-reset.json")" = "true" ]
  refute_grep 'master context reset loop' "$LOG"
}

@test "B5: guard judges the session's FIRST reading, not growth since the reset" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  # the resumed master is already over threshold, but its post-/clear floor was small
  jq -nc '{pct:90,tokens:500000,window:1000000,session_id:"b",first:{pct:12,tokens:60000}}' \
    > "$STATE_DIR/master-context.json"; sess b
  start_hb
  wait_for jq -e '.verified == true' "$STATE_DIR/master-reset.json"
  stop_hb
  [ "$(jq '.backoff // false' "$STATE_DIR/master-reset.json")" = "false" ]
  refute_grep 'master context reset loop' "$LOG"
}

@test "B5: guard backs off when the session's FIRST reading was over threshold" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  jq -nc '{pct:90,tokens:500000,window:1000000,session_id:"b",first:{pct:70,tokens:400000}}' \
    > "$STATE_DIR/master-context.json"; sess b
  start_hb
  wait_for jq -e '.backoff == true' "$STATE_DIR/master-reset.json"
  stop_hb
  grep -q 'master context reset loop' "$LOG"
}

@test "B5: orch up (bootstrap) clears the backoff" {
  tk="$BATS_TEST_TMPDIR/toolkit"; mkdir -p "$tk/_orch"
  for f in bootstrap.sh lib.sh rehydrate.sh master-statusline.sh master-session-start.sh; do
    cp "$REPO/_orch/$f" "$tk/_orch/$f"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tk/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tk/_orch/watchdog.sh"
  chmod +x "$tk"/_orch/*.sh
  cp "$ORCH_ROOT/_orch/config.json" "$tk/_orch/config.json"
  mkdir -p "$tk/_orch/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"; chmod +x "$STUBBIN/claude"
  jq -nc '{ts:1,old_session_id:"a",backoff:true}' > "$tk/_orch/state/master-reset.json"
  echo 99999999999 > "$tk/_orch/state/master-reset-retry-after"
  PROJECT_ROOT="$BATS_TEST_TMPDIR/proj" ORCH_ROOT="$tk" SESSION_NAME=orch_i160_bs run "$tk/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$tk/_orch/state/master-reset.json" ]
  [ ! -e "$tk/_orch/state/master-reset-retry-after" ]
}

# ---------------------------------------------------------------- review fixes
@test "B6: a notes write in the same second as the checkpoint (before it was read) does not count" {
  # No TOUCH_FLAG: the master never rewrites notes after the prompt. Its
  # previous turn's write must not count; a future mtime makes ">= t0" true
  # deterministically, so only the "mtime moved" check can stop the /clear.
  touch -d "@$(( $(date +%s) + 60 ))" "$NOTES"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'master reset aborted' "$LOG"
  stop_hb
  refute_grep '/clear' "$CALLS"
  [ ! -e "$STATE_DIR/master-reset.json" ]
}

@test "B6: a successful reset wakes the master with a master-reset event" {
  touch "$TOUCH_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'woke master with.*master-reset' "$LOG"
  stop_hb
  clr_line="$(grep -n 'PASTE<</clear>>' "$CALLS" | head -1 | cut -d: -f1)"
  wake_line="$(grep -n '"event":"master-reset"' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$clr_line" ]
  [ -n "$wake_line" ]
  [ "$clr_line" -lt "$wake_line" ]
}

@test "B6: an aborted reset tells the master (master-reset-aborted event)" {
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'woke master with.*master-reset-aborted' "$LOG"
  stop_hb
  grep -q '"event":"master-reset-aborted"' "$STATE_DIR/events.jsonl"
  refute_grep '/clear' "$CALLS"
}

@test "B7: the abort throttle is persisted, so a restarted heartbeat does not re-checkpoint" {
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'master reset aborted' "$LOG"
  stop_hb
  ra="$(cat "$STATE_DIR/master-reset-retry-after")"
  [ "$ra" -gt "$(date +%s)" ]
  : > "$CALLS"; rm -f "$STATE_DIR/.stop"
  touch "$TOUCH_FLAG"
  start_hb
  sleep 0.7
  stop_hb
  grep -q 'capture-pane' "$CALLS"   # the heartbeat did tick
  refute_grep 'master-notes.md' "$CALLS"
  refute_grep '/clear' "$CALLS"
}

@test "B8: /clear whose session id never changes -> unconfirmed, resets latched off, master told" {
  touch "$TOUCH_FLAG" "$NO_CLEAR_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'master reset unconfirmed' "$LOG"
  stop_hb
  grep -q 'PASTE<</clear>>' "$CALLS"
  # latched off (no reset recorded as done) until orch up
  [ "$(jq .backoff "$STATE_DIR/master-reset.json")" = "true" ]
  jq -e 'has("verified") | not' "$STATE_DIR/master-reset.json"
  [ "$(grep -c 'PASTE<</clear>>' "$CALLS")" -eq 1 ]
  grep -q '"event":"master-reset-aborted"' "$STATE_DIR/events.jsonl"
  refute_grep '"event":"master-reset"' "$STATE_DIR/events.jsonl"
}

@test "B8: a pct-only reading (tokens null, possibly stale) is never due" {
  run due '{"pct":75,"tokens":null,"window":1000000,"session_id":"s1"}' "$S1" '{}' 60 0.35 1800
  [ "$status" -eq 1 ]
}

@test "B8: a non-numeric master_context knob disables resets and says so" {
  jq '.master_context.reset_pct = "60%"' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$ORCH_ROOT/_orch/config.json"
  touch "$TOUCH_FLAG"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q "non-numeric setting '60%'" "$LOG"
  sleep 0.3
  stop_hb
  [ "$(grep -c 'non-numeric setting' "$LOG")" -eq 1 ]
  refute_grep 'master-notes.md' "$CALLS"
}

@test "B8: .stop during the checkpoint wait ends it promptly without /clear" {
  jq '.master_context.checkpoint_timeout_s = 600' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$ORCH_ROOT/_orch/config.json"
  ctx 75 400000 s1; sess s1
  start_hb
  wait_for grep -q 'checkpoint requested' "$LOG"
  stop_hb
  grep -q 'master reset aborted: heartbeat stopping' "$LOG"
  refute_grep '/clear' "$CALLS"
}

@test "B9: a pct-only post-/clear record (tokens null, stale pct) neither backs off nor verifies" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  # stale pct over threshold, no real reading yet (.first null)
  jq -nc '{pct:75,tokens:null,window:1000000,session_id:"b",first:null}' > "$STATE_DIR/master-context.json"; sess b
  master_reset_guard "$(cat "$STATE_DIR/master-context.json")" "$(cat "$STATE_DIR/master-reset.json")" 60 0.35
  [ "$(jq '.backoff // false' "$STATE_DIR/master-reset.json")" = "false" ]
  [ "$(jq '.verified // false' "$STATE_DIR/master-reset.json")" = "false" ]
  # stale pct of 0: must not "verify" an unmeasured floor either
  jq -nc '{pct:0,tokens:null,window:1000000,session_id:"b",first:null}' > "$STATE_DIR/master-context.json"
  master_reset_guard "$(cat "$STATE_DIR/master-context.json")" "$(cat "$STATE_DIR/master-reset.json")" 60 0.35
  [ "$(jq '.verified // false' "$STATE_DIR/master-reset.json")" = "false" ]
}

@test "B9: the loop-guard log reports the judged FIRST reading, not the current one" {
  jq -nc '{ts:1,old_session_id:"a",pct:80,tokens:400000}' > "$STATE_DIR/master-reset.json"
  jq -nc '{pct:90,tokens:500000,window:1000000,session_id:"b",first:{pct:70,tokens:400000}}' > "$STATE_DIR/master-context.json"
  master_reset_guard "$(cat "$STATE_DIR/master-context.json")" "$(cat "$STATE_DIR/master-reset.json")" 60 0.35
  [ "$(jq .backoff "$STATE_DIR/master-reset.json")" = "true" ]
  grep -q 'reset loop: .*(pct=70 tokens=400000)' "$LOG"
}
