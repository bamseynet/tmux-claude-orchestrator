#!/usr/bin/env bats
# Hermetic tests for issue #210: worker context tracking.
#   _orch/worker-statusline.sh <id> <skip-settings-path>  records context usage
#     to state/worker-context/<id>.json and CHAINS to the next-lower layer's bar
#   spawn.sh installs it; clean.sh removes the record; `orch status` shows CTX%
#   heartbeat.sh worker_context_tick emits context-high / context-full once per
#     crossing.
# tmux/claude/git are stubbed; HOME and ORCH_ROOT live under $BATS_TEST_TMPDIR.

REPO="$BATS_TEST_DIRNAME/.."
FIXTURE="$BATS_TEST_DIRNAME/fixtures/statusline_worker_real.json"
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  WINDOWS="$BATS_TEST_TMPDIR/windows"
  : > "$WINDOWS"
  export WINDOWS
  cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "${SESSION_NAME:-orch}" ;;
  list-windows)  cat "$WINDOWS" ;;
  capture-pane)  echo '> ready for shortcuts' ;;
  show-buffer)   exit 1 ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$BATS_TEST_DIRNAME/helpers/fake-git.bash"
  install_fake_git "$STUBBIN"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  unset CLAUDE_CONFIG_DIR
  export ORCH_ROOT="$BATS_TEST_TMPDIR/toolkit"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch_i210_test"
  mkdir -p "$ORCH_ROOT" "$PROJECT_ROOT"
  cp -r "$REPO/_orch" "$ORCH_ROOT/_orch"
  cp "$REPO/orch" "$ORCH_ROOT/orch"
  rm -rf "$ORCH_ROOT/_orch/state"
  STATE="$ORCH_ROOT/_orch/state"
  mkdir -p "$STATE/workers"
  jq '.watchdog.enabled = false | .thresholds.min_free_mb = 0 | .thresholds.est_worker_mb = 0 | .budget.enabled = false' \
    "$REPO/_orch/config.json" > "$ORCH_ROOT/_orch/config.json"
  SL="$ORCH_ROOT/_orch/worker-statusline.sh"
  MSL="$ORCH_ROOT/_orch/master-statusline.sh"

  # operator layers for the chaining tests
  CWD="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$CWD/.claude"
  cd "$CWD"
}

teardown() {
  touch "$STATE/.stop" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  wait "${HB_PID:-}" 2>/dev/null || true
}

# a status-line command that prints a tag so we can tell which layer answered
mkbar() { # <name> <settings-file> [text]
  local b="$BATS_TEST_TMPDIR/bar-$1.sh"
  printf '#!/usr/bin/env bash\necho "%s"\n' "${3:-BAR-$1}" > "$b"
  chmod +x "$b"
  jq -n --arg c "$b" '{statusLine:{type:"command",command:$c}}' > "$2"
}

run_sl() { # <stdin> <args...>
  local in="$1"; shift
  run bash -c 'printf "%s" "$1" | "${@:2}"' _ "$in" "$SL" "$@"
}

# ---------------------------------------------------------------- 1 capture
@test "capture: real payload fixture -> exact pct/tokens/window/session_id" {
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  f="$STATE/worker-context/w1.json"
  [ -f "$f" ]
  [ "$(jq '.pct' "$f")" = "5" ]
  [ "$(jq '.tokens' "$f")" = "54954" ]   # 2 + 26649 + 28303 (current_usage)
  [ "$(jq '.window' "$f")" = "1000000" ]
  [ "$(jq -r '.session_id' "$f")" = "466ab93c-ba12-4a60-b0cc-7c7c5d4bc69b" ]
  [ "$(jq -r '.ts' "$f")" != "null" ]
  [ "$(jq '.reset' "$f")" = "false" ]
}

@test "capture: present-but-null current_usage is a reset, not a reading" {
  in='{"session_id":"s9","context_window":{"used_percentage":0,"current_usage":null,"context_window_size":200000}}'
  run_sl "$in" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  f="$STATE/worker-context/w1.json"
  [ "$(jq '.reset' "$f")" = "true" ]
  [ "$(jq '.tokens' "$f")" = "null" ]
}

@test "capture: tokens come from current_usage, not the cumulative total" {
  in='{"session_id":"s1","context_window":{"used_percentage":10,"total_input_tokens":900000,"current_usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":85},"context_window_size":200000}}'
  run_sl "$in" w1 "$CWD/.claude/settings.local.json"
  [ "$(jq '.tokens' "$STATE/worker-context/w1.json")" = "100" ]
}

@test "capture: missing current_usage key falls back to total_input_tokens" {
  in='{"session_id":"s1","context_window":{"used_percentage":40,"total_input_tokens":80000,"context_window_size":200000}}'
  run_sl "$in" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.tokens' "$STATE/worker-context/w1.json")" = "80000" ]
  [ "$(jq '.reset' "$STATE/worker-context/w1.json")" = "false" ]
}

@test "capture: malformed/empty stdin exits 0 and keeps the previous record" {
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  cp "$STATE/worker-context/w1.json" "$BATS_TEST_TMPDIR/good.json"
  for bad in '' 'not json' '{"session_id":"s2","context_window":{"used_percentage":null,"total_input_tokens":0}}'; do
    run_sl "$bad" w1 "$CWD/.claude/settings.local.json"
    [ "$status" -eq 0 ]
    cmp "$STATE/worker-context/w1.json" "$BATS_TEST_TMPDIR/good.json"
  done
}

@test "capture: exits 0 with no id / no args and writes nothing" {
  run_sl "$(cat "$FIXTURE")"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/worker-context" ] || [ -z "$(ls -A "$STATE/worker-context")" ]
}

@test "capture: rejects a path-traversal id" {
  run_sl "$(cat "$FIXTURE")" "../evil" "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/evil.json" ]
  [ ! -e "$ORCH_ROOT/_orch/evil.json" ]
}

# ---------------------------------------------------------------- 2 chaining
@test "chain: skips its own settings.local.json layer and prints the repo bar" {
  jq -n --arg c "$SL w1 $CWD/.claude/settings.local.json" '{statusLine:{type:"command",command:$c}}' > "$CWD/.claude/settings.local.json"
  mkbar repo "$CWD/.claude/settings.json"
  mkbar user "$HOME/.claude/settings.json"
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-repo"* ]]
  [[ "$output" != *"BAR-user"* ]]
}

@test "chain: falls through to the user bar when the repo defines none" {
  jq -n --arg c "$SL w1 $CWD/.claude/settings.local.json" '{statusLine:{type:"command",command:$c}}' > "$CWD/.claude/settings.local.json"
  mkbar user "$HOME/.claude/settings.json"
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-user"* ]]
}

@test "chain: --no-worktree private settings file (not a layer) still reaches the repo's own local bar" {
  mkdir -p "$STATE/settings"
  jq -n --arg c "$SL w1 $STATE/settings/w1.json" '{statusLine:{type:"command",command:$c}}' > "$STATE/settings/w1.json"
  mkbar local "$CWD/.claude/settings.local.json"
  run_sl "$(cat "$FIXTURE")" w1 "$STATE/settings/w1.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-local"* ]]
}

@test "chain: the skip-path layer is skipped by identity, not only by the script-name filter" {
  # Own layer holds a bar WITHOUT worker-statusline.sh in its command, so only
  # the <skip-settings-path> (-ef) check can keep it from being chained to.
  mkbar own "$CWD/.claude/settings.local.json"
  mkbar repo "$CWD/.claude/settings.json"
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-repo"* ]]
  [[ "$output" != *"BAR-own"* ]]
}

@test "chain: no bar anywhere -> a minimal line, never empty" {
  jq -n --arg c "$SL w1 $CWD/.claude/settings.local.json" '{statusLine:{type:"command",command:$c}}' > "$CWD/.claude/settings.local.json"
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "chain: chained output is scrubbed of pane-heuristic glyphs and words" {
  jq -n --arg c "$SL w1 $CWD/.claude/settings.local.json" '{statusLine:{type:"command",command:$c}}' > "$CWD/.claude/settings.local.json"
  mkbar repo "$CWD/.claude/settings.json" '❯ a > b │ ✻ esc to interrupt Compacting Welcome …'
  run_sl "$(cat "$FIXTURE")" w1 "$CWD/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  for bad in '❯' '>' '│' '✻' '…'; do [[ "$output" != *"$bad"* ]]; done
  shopt -s nocasematch
  [[ "$output" != *"esc to interrupt"* ]]
  [[ "$output" != *"compacting"* ]]
  [[ "$output" != *"welcome"* ]]
}

@test "chain control: master-statusline.sh loses the repo/user bar in the same setup" {
  jq -n --arg c "$MSL" '{statusLine:{type:"command",command:$c}}' > "$CWD/.claude/settings.local.json"
  mkbar repo "$CWD/.claude/settings.json"
  mkbar user "$HOME/.claude/settings.json"
  run bash -c 'printf "%s" "$1" | "$2"' _ "$(cat "$FIXTURE")" "$MSL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BAR-repo"* ]]
  [[ "$output" != *"BAR-user"* ]]
}

# ---------------------------------------------------------------- 3 spawn
spawn_with_repo_bar() { # <mode flag or empty>
  mkdir -p "$PROJECT_ROOT/.claude"
  mkbar repo "$PROJECT_ROOT/.claude/settings.json"
  run "$ORCH_ROOT/_orch/spawn.sh" sp1 sonnet "do it" $1
  [ "$status" -eq 0 ]
}

@test "spawn (worktree): settings.local.json gets our statusLine, hooks unchanged, chain reaches repo bar" {
  spawn_with_repo_bar ""
  wd="$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "$1/_orch/lib.sh"; worker_wdir "$2" sp1' _ "$ORCH_ROOT" "$PROJECT_ROOT")"
  sf="$wd/.claude/settings.local.json"
  [ -f "$sf" ]
  cmd="$(jq -r '.statusLine.command' "$sf")"
  [[ "$cmd" == *"worker-statusline.sh"* ]]
  [[ "$cmd" == *"sp1"* ]]
  [[ "$cmd" == *"$sf"* ]]
  [ "$(jq -r '.statusLine.type' "$sf")" = "command" ]
  [ "$(jq '.hooks | keys | length' "$sf")" -ge 4 ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$sf")" = "$ORCH_ROOT/_orch/report.sh sp1 done --hook" ]
  # the generated file chains to the project bar when run from the worktree dir
  mkdir -p "$wd/.claude"; cp "$PROJECT_ROOT/.claude/settings.json" "$wd/.claude/settings.json"
  cd "$wd"
  run bash -c 'printf "%s" "$1" | bash -c "$2"' _ "$(cat "$FIXTURE")" "$cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-repo"* ]]
  [ -f "$STATE/worker-context/sp1.json" ]
}

@test "spawn (--no-worktree): private settings file gets our statusLine and chains to the repo bar" {
  spawn_with_repo_bar "--no-worktree"
  sf="$STATE/settings/sp1.json"
  cmd="$(jq -r '.statusLine.command' "$sf")"
  [[ "$cmd" == *"worker-statusline.sh"* ]]
  [[ "$cmd" == *"sp1"* ]]
  [[ "$cmd" == *"$sf"* ]]   # skip path = the private --settings file, not a layer
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$sf")" = "$ORCH_ROOT/_orch/report.sh sp1 done --hook" ]
  cp "$PROJECT_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/settings.local.json"
  cd "$PROJECT_ROOT"
  run bash -c 'printf "%s" "$1" | bash -c "$2"' _ "$(cat "$FIXTURE")" "$cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BAR-repo"* ]]
}

@test "spawn: a same-id respawn without clean drops the previous run's context record and marker" {
  # A dead worker's id can be respawned in the same repo without `orch clean`
  # (#177 only blocks a different repo). Its old 97% reading -- never ticked
  # while the master was down -- must not fire context-full at the fresh worker.
  mkdir -p "$STATE/worker-context"
  echo '{"pct":97,"session_id":"old","ts":"2026-11-11T10:00:00Z","reset":false}' > "$STATE/worker-context/sp1.json"
  echo 'high old' > "$STATE/.ctx-sp1"
  run "$ORCH_ROOT/_orch/spawn.sh" sp1 sonnet "do it"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/worker-context/sp1.json" ]
  [ ! -e "$STATE/.ctx-sp1" ]
}

# ---------------------------------------------------------------- 8 clean
@test "clean removes worker-context/<id>.json and .ctx-<id>" {
  mkdir -p "$STATE/worker-context"
  echo '{"pct":50}' > "$STATE/worker-context/cl1.json"
  echo high > "$STATE/.ctx-cl1"
  echo '{"pct":50}' > "$STATE/worker-context/keep.json"
  run "$ORCH_ROOT/_orch/clean.sh" cl1
  [ ! -e "$STATE/worker-context/cl1.json" ]
  [ ! -e "$STATE/.ctx-cl1" ]
  [ -e "$STATE/worker-context/keep.json" ]
}

# ---------------------------------------------------------------- 7 status
mkworker() { # <id> <status>
  jq -n --arg id "$1" --arg s "$2" '{id:$id,status:$s,model:"sonnet",task:"t",created:"2020-01-01T00:00:00Z",updated:"2020-01-01T00:00:00Z"}' > "$STATE/workers/$1.json"
}
mkctx() { # <id> <pct> [session_id] [reset]
  mkdir -p "$STATE/worker-context"
  jq -nc --argjson p "$2" --arg s "${3:-s1}" --argjson r "${4:-false}" \
    '{pct:$p,tokens:($p*1000),window:100000,session_id:$s,ts:"2026-11-11T10:00:00Z",reset:$r}' > "$STATE/worker-context/$1.json"
}
ostatus() { run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_ROOT/orch" status "$@"; }

@test "status --json includes context.pct; absent record is null" {
  mkworker a working; mkworker b working
  mkctx a 72
  ostatus --json
  [ "$status" -eq 0 ]
  [ "$(jq '.[] | select(.id=="a") | .context.pct' <<<"$output")" = "72" ]
  [ "$(jq '.[] | select(.id=="a") | .context.window' <<<"$output")" = "100000" ]
  [ "$(jq '.[] | select(.id=="b") | .context' <<<"$output")" = "null" ]
}

@test "status table shows CTX% column; missing record is '-', never 0" {
  mkworker a working; mkworker b working
  mkctx a 72
  ostatus
  [ "$status" -eq 0 ]
  [[ "$output" == *"CTX%"* ]]
  la="$(grep -E '^a ' <<<"$output")"; lb="$(grep -E '^b ' <<<"$output")"
  [[ "$la" == *"72%"* ]]
  [[ "$lb" == *" - "* ]]
  [[ "$lb" != *"0%"* ]]
}

@test "status: CTX% truncates like the heartbeat (69.6 shows 69%, never a 70% with no context-high)" {
  mkworker a working
  mkctx a 69.6
  ostatus
  [ "$status" -eq 0 ]
  la="$(grep -E '^a ' <<<"$output")"
  [[ "$la" == *"69%"* ]]
  [[ "$la" != *"70%"* ]]
}

@test "status: a reset record renders '-' (unknown), not a stale pct" {
  mkworker a working
  mkctx a 0 s1 true
  ostatus
  [ "$status" -eq 0 ]
  la="$(grep -E '^a ' <<<"$output")"
  [[ "$la" == *" - "* ]]
  [[ "$la" != *"0%"* ]]
}

@test "glob regression: worker-context/ creates no phantom worker in status/rehydrate" {
  mkworker a working
  mkctx a 50
  mkctx ghost 50
  ostatus --json
  [ "$(jq 'length' <<<"$output")" = "1" ]
  run "$ORCH_ROOT/_orch/rehydrate.sh"
  [[ "$output" != *"ghost"* ]]
}

# ---------------------------------------------------------------- 4/5 events
load_hb() {
  # shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
  source "$ORCH_ROOT/_orch/heartbeat.sh"
  : > "$INBOX"; : > "$STATE_DIR/events.jsonl"
}
ev_count() { # <event> -> count in inbox
  jq -r --arg e "$1" 'select(.event==$e) | .id' "$INBOX" 2>/dev/null | wc -l | tr -d ' '
}
live() { echo "$1" >> "$WINDOWS"; mkworker "$1" "${2:-working}"; }

@test "events: context-high fires once per crossing, re-arms below warn-10" {
  load_hb; live w1
  mkctx w1 50; worker_context_tick;                       [ "$(ev_count context-high)" = 0 ]
  mkctx w1 71; worker_context_tick;                       [ "$(ev_count context-high)" = 1 ]
  for _ in 1 2 3 4; do mkctx w1 80; worker_context_tick; done
  [ "$(ev_count context-high)" = 1 ]
  mkctx w1 65; worker_context_tick; mkctx w1 75; worker_context_tick   # not below 60: still armed-off
  [ "$(ev_count context-high)" = 1 ]
  mkctx w1 55; worker_context_tick; mkctx w1 72; worker_context_tick   # fell below 60, crosses again
  [ "$(ev_count context-high)" = 2 ]
  # same event in events.jsonl, with id and pct
  [ "$(jq -r 'select(.event=="context-high") | .id' "$STATE_DIR/events.jsonl" | wc -l | tr -d ' ')" = 2 ]
  [ "$(jq -r 'select(.event=="context-high") | .pct' "$STATE_DIR/events.jsonl" | head -1)" = 71 ]
}

@test "events: context-full fires once at full_pct, separately from context-high" {
  load_hb; live w1
  mkctx w1 96; worker_context_tick
  [ "$(ev_count context-full)" = 1 ]
  [ "$(ev_count context-high)" = 0 ]
  for _ in 1 2 3; do mkctx w1 97; worker_context_tick; done
  [ "$(ev_count context-full)" = 1 ]
  mkctx w1 80; worker_context_tick                 # 80 < 95-10: full re-armed; 80 >= 70-10: high stays fired
  [ "$(ev_count context-high)" = 0 ]
  mkctx w1 96; worker_context_tick
  [ "$(ev_count context-full)" = 2 ]
}

@test "events: a reset record or a new session_id re-arms" {
  load_hb; live w1
  mkctx w1 80 sA; worker_context_tick
  # a STALE pct (80, above the re-arm line) on the reset record: only the reset
  # path can re-arm here, the pct-drop path cannot
  mkctx w1 80 sA true; worker_context_tick
  mkctx w1 80 sA; worker_context_tick
  [ "$(ev_count context-high)" = 2 ]
  mkctx w1 80 sB; worker_context_tick
  [ "$(ev_count context-high)" = 3 ]
}

@test "events: a reset record with a null pct (real /clear payload) still re-arms" {
  load_hb; live w1
  mkctx w1 80 sA; worker_context_tick
  [ "$(ev_count context-high)" = 1 ]
  # what worker-statusline.sh records for used_percentage:null + current_usage:null
  run_sl '{"session_id":"sA","context_window":{"used_percentage":null,"context_window_size":200000,"current_usage":null}}' \
    w1 "$CWD/.claude/settings.local.json"
  [ "$(jq '.reset' "$STATE/worker-context/w1.json")" = "true" ]
  [ "$(jq '.pct' "$STATE/worker-context/w1.json")" = "null" ]
  worker_context_tick
  [ ! -s "$STATE_DIR/.ctx-w1" ] || [ "$(cut -d' ' -f1 "$STATE_DIR/.ctx-w1")" = none ]
  mkctx w1 80 sA; worker_context_tick
  [ "$(ev_count context-high)" = 2 ]
}

@test "events: a small warn_pct (<= 20) still re-arms after a drop" {
  load_hb; live w1
  jq '.worker_context = {enabled:true, warn_pct:5, full_pct:50}' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""
  mkctx w1 6 sA; worker_context_tick
  [ "$(ev_count context-high)" = 1 ]
  mkctx w1 1 sA; worker_context_tick; mkctx w1 7 sA; worker_context_tick   # same session, no reset
  [ "$(ev_count context-high)" = 2 ]
}

@test "events: an orphan context record (no worker JSON) leaves no .ctx marker" {
  load_hb
  mkctx ghost 10                      # below warn: no event, so the marker write is reached
  worker_context_tick
  [ ! -e "$STATE_DIR/.ctx-ghost" ]
  [ ! -s "$INBOX" ]
}

@test "events: a marker written without a session_id still re-arms on a new session" {
  load_hb; live w1
  mkdir -p "$STATE/worker-context"
  echo '{"pct":75,"ts":"2026-11-11T10:00:00Z","reset":false}' > "$STATE/worker-context/w1.json"
  worker_context_tick
  [ "$(ev_count context-high)" = 1 ]
  mkctx w1 75 sX; worker_context_tick          # new session, never fell below warn-10
  [ "$(ev_count context-high)" = 2 ]
}

@test "events: a done worker at 97% emits; dead / spawn-failed / missing window do not" {
  load_hb
  live d1 done
  mkctx d1 97
  live x1 dead;            mkctx x1 97
  live x2 spawn-failed;    mkctx x2 97
  mkworker gone working;   mkctx gone 97                 # no window
  worker_context_tick
  [ "$(jq -r 'select(.event=="context-full") | .id' "$INBOX")" = "d1" ]
}

@test "events: canary - nothing for no record, below warn, unparseable record, disabled" {
  load_hb; live w1; live w2; live w3
  mkctx w1 10
  mkdir -p "$STATE/worker-context"; echo 'garbage{' > "$STATE/worker-context/w2.json"
  echo '{"pct":"high","session_id":"s","ts":"x"}' > "$STATE/worker-context/w3.json"
  worker_context_tick
  [ ! -s "$INBOX" ]
  # disabled
  mkctx w1 99
  jq '.worker_context = {enabled:false}' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""; worker_context_tick
  [ ! -s "$INBOX" ]
}

@test "events: a malformed record file does not block other workers' events" {
  load_hb; live a1; live z1
  mkdir -p "$STATE/worker-context"; echo 'garbage{' > "$STATE/worker-context/a1.json"
  mkctx z1 90
  worker_context_tick
  [ "$(jq -r 'select(.event=="context-high") | .id' "$INBOX")" = "z1" ]
}

@test "events: invalid threshold logs and disables (not silently on)" {
  load_hb; live w1; mkctx w1 99
  jq '.worker_context = {enabled:true, warn_pct:"abc", full_pct:95}' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""; worker_context_tick
  [ ! -s "$INBOX" ]
  grep -q "worker_context: invalid setting" "$LOG"
  # warn >= full is also invalid
  jq '.worker_context = {enabled:true, warn_pct:96, full_pct:95}' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""; worker_context_tick
  [ ! -s "$INBOX" ]
}

@test "events: a non-object worker_context (false / \"off\") disables and logs, never silently on" {
  load_hb; live w1; mkctx w1 99
  jq '.worker_context = false' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""; worker_context_tick
  [ ! -s "$INBOX" ]
  grep -q "worker_context: invalid setting" "$LOG"
  : > "$LOG"
  jq '.worker_context = "off"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  _WORKER_CTX_CFG=""; worker_context_tick
  [ ! -s "$INBOX" ]
  grep -q "worker_context: invalid setting" "$LOG"
}

@test "events: shipped config enables worker_context at 70/95 and does not denylist the events" {
  [ "$(jq -r '.worker_context.enabled' "$REPO/_orch/config.json")" = "true" ]
  [ "$(jq -r '.worker_context.warn_pct' "$REPO/_orch/config.json")" = "70" ]
  [ "$(jq -r '.worker_context.full_pct' "$REPO/_orch/config.json")" = "95" ]
  [ "$(jq -r '.heartbeat.inject_denylist | map(select(startswith("context"))) | length' "$REPO/_orch/config.json")" = "0" ]
}

@test "canary: 'Context limit reached' is not matched by the rate-limit regex" {
  re="$(jq -r '.watchdog.rate_limit_regex' "$REPO/_orch/config.json")"
  run grep -Eq "$re" <<<'⎿ Context limit reached · /compact or /clear to continue'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------- 6 delivery
@test "delivery: context-high is delivered to the master exactly once while the worker stays above" {
  PASTED="$BATS_TEST_TMPDIR/pasted.txt"; : > "$PASTED"
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  list-sessions) echo "\$SESSION_NAME" ;;
  list-windows)  cat "$WINDOWS" ;;
  capture-pane)  printf '❯ \n? for shortcuts' ;;
  load-buffer)   cat >> "$PASTED" ;;
  show-buffer)   exit 1 ;;
esac
exit 0
STUB
  export ORCH_WINDOW=orchestrator
  jq '.intervals.normal_seconds = 0 | .intervals.idle_seconds = 0' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c" \
    && mv "$BATS_TEST_TMPDIR/c" "$ORCH_ROOT/_orch/config.json"
  load_hb; live w1; mkctx w1 85
  heartbeat_main & HB_PID=$!
  for _ in $(seq 1 200); do grep -q context-high "$PASTED" && break; sleep 0.02; done
  grep -q context-high "$PASTED"
  sleep 1                                  # many more ticks (0s interval) with the worker still at 85%
  touch "$STATE_DIR/.stop"; wait "$HB_PID" 2>/dev/null || true
  [ "$(grep -o context-high "$PASTED" | wc -l | tr -d ' ')" = 1 ]
}
