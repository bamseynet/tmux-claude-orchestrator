#!/usr/bin/env bats
# Hermetic tests for issue #159 (#158 part A): the master gets its own settings
# file (status-line capture + SessionStart rehydrate) and an earlier
# auto-compact window. Nothing here types into a master pane. tmux/claude/git are
# stubbed; HOME and ORCH_ROOT live under $BATS_TEST_TMPDIR.

REPO="$BATS_TEST_DIRNAME/.."
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_LOG
  : > "$TMUX_LOG"
  cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$TMUX_LOG"
case "${1:-}" in
  has-session)  exit 1 ;;
  list-sessions) [ -e "$TMUX_LOG.up" ] && echo "${SESSION_NAME:-orch}"; exit 0 ;;
  list-windows) exit 0 ;;
  capture-pane) echo '> ready for shortcuts' ;;
  show-buffer)  exit 1 ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  cat > "$STUBBIN/git" <<'STUB'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  mkdir -p "${args[$((${#args[@]}-1))]}"
fi
exit 0
STUB
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude" "$STUBBIN/git"
  PATH="$STUBBIN:$PATH"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR
  export ORCH_ROOT="$BATS_TEST_TMPDIR/toolkit"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch_i159_test"
  mkdir -p "$ORCH_ROOT/_orch" "$PROJECT_ROOT"
  STATE="$ORCH_ROOT/_orch/state"
  mkdir -p "$STATE/workers"
  # a toolkit copy so bootstrap/spawn/clean resolve $here to the tmp dir
  for f in bootstrap.sh lib.sh spawn.sh clean.sh rehydrate.sh master-statusline.sh \
           master-session-start.sh worker-settings.template.json; do
    [ -e "$REPO/_orch/$f" ] && cp "$REPO/_orch/$f" "$ORCH_ROOT/_orch/$f"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ORCH_ROOT/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ORCH_ROOT/_orch/watchdog.sh"
  chmod +x "$ORCH_ROOT"/_orch/*.sh
  jq -n '{watchdog:{enabled:false}, thresholds:{max_workers:4,min_free_mb:0,est_worker_mb:0}, budget:{enabled:false}}' \
    > "$ORCH_ROOT/_orch/config.json"
  SL="$ORCH_ROOT/_orch/master-statusline.sh"
  SS="$ORCH_ROOT/_orch/master-session-start.sh"
}

# ---------------------------------------------------------------- A1
@test "A1: status line captures context usage and leaves a good file alone on bad input" {
  in='{"session_id":"s1","context_window":{"used_percentage":72.5,"total_input_tokens":410000,"context_window_size":1000000}}'
  run bash -c 'printf "%s" "$1" | "$2"' _ "$in" "$SL"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(jq '.pct' "$STATE/master-context.json")" = "72.5" ]
  [ "$(jq '.tokens' "$STATE/master-context.json")" = "410000" ]
  [ "$(jq -r '.session_id' "$STATE/master-context.json")" = "s1" ]
  [ "$(jq '.window' "$STATE/master-context.json")" = "1000000" ]

  cp "$STATE/master-context.json" "$BATS_TEST_TMPDIR/good.json"
  for bad in '' 'not json' '{"session_id":"s2","context_window":{"used_percentage":null,"total_input_tokens":0}}'; do
    run bash -c 'printf "%s" "$1" | "$2"' _ "$bad" "$SL"
    [ "$status" -eq 0 ]
    cmp "$STATE/master-context.json" "$BATS_TEST_TMPDIR/good.json"
  done
}

@test "A1: status line output cannot match the pane heuristics" {
  in='{"session_id":"s1","context_window":{"used_percentage":72.5,"total_input_tokens":410000,"context_window_size":1000000}}'
  run bash -c 'printf "%s" "$1" | "$2"' _ "$in" "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"❯"* ]]
  [[ "$output" != *">"* ]]
  [[ "$output" != *"│"* ]]
}

# ---------------------------------------------------------------- A2
@test "A2: status line chains to the operator's own statusLine.command" {
  mkdir -p "$HOME/.claude"
  cat > "$BATS_TEST_TMPDIR/userbar.sh" <<'STUB'
#!/usr/bin/env bash
echo "USER-BAR:$(jq -r .session_id)"
STUB
  chmod +x "$BATS_TEST_TMPDIR/userbar.sh"
  jq -n --arg c "$BATS_TEST_TMPDIR/userbar.sh" '{statusLine:{type:"command",command:$c}}' > "$HOME/.claude/settings.json"
  in='{"session_id":"s1","context_window":{"used_percentage":10,"total_input_tokens":5,"context_window_size":1000000}}'
  run bash -c 'printf "%s" "$1" | "$2"' _ "$in" "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER-BAR:s1"* ]]
}

@test "A2: chained operator status line is scrubbed of pane-heuristic glyphs" {
  mkdir -p "$HOME/.claude"
  printf '#!/usr/bin/env bash\necho "❯ dir > branch │ x ╭╮"\n' > "$BATS_TEST_TMPDIR/userbar.sh"
  chmod +x "$BATS_TEST_TMPDIR/userbar.sh"
  jq -n --arg c "$BATS_TEST_TMPDIR/userbar.sh" '{statusLine:{type:"command",command:$c}}' > "$HOME/.claude/settings.json"
  run bash -c 'printf "%s" "{}" | "$1"' _ "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dir"*"branch"* ]]
  [[ "$output" != *"❯"* ]]
  [[ "$output" != *">"* ]]
  [[ "$output" != *"│"* ]]
}

# ---------------------------------------------------------------- A3
seed_state() {
  echo '{"id":"wz9","status":"working","model":"sonnet","task":"canary task"}' > "$STATE/workers/wz9.json"
  { echo "NOTES-CANARY-TOP"; head -c 51200 /dev/zero | tr '\0' 'x'; echo; } > "$STATE/master-notes.md"
}

run_ss() { # <source> <session_id>
  run bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"source\":\"%s\",\"session_id\":\"%s\"}" "$1" "$2" | "$3"' _ "$1" "$2" "$SS"
}

@test "A3: SessionStart on clear and compact rehydrates within the 10k cap" {
  seed_state
  for src in clear compact; do
    rm -f "$STATE/master-session.json"
    run_ss "$src" new1
    [ "$status" -eq 0 ]
    ctx="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ctx" == *"You are the ORCHESTRATOR"* ]]
    [[ "$ctx" == *"wz9"* ]]
    [ "$(printf '%s' "$output" | jq '.hookSpecificOutput.additionalContext|length')" -le 10000 ]
    # role prompt first
    [[ "$ctx" == "You are the ORCHESTRATOR"* ]]
    [ "$(jq -r .session_id "$STATE/master-session.json")" = "new1" ]
  done
}

@test "A3: over-cap rehydrate keeps the tail (newest notes + reconcile line)" {
  seed_state
  echo "NOTES-CANARY-BOTTOM" >> "$STATE/master-notes.md"
  run_ss compact new4
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$ctx" == *"NOTES-CANARY-BOTTOM"* ]]
  [[ "$ctx" == *"Reconcile the above"* ]]
  [ "$(printf '%s' "$output" | jq '.hookSpecificOutput.additionalContext|length')" -le 9500 ]
}

@test "A3: rehydrate larger than one argv string (128 KiB) still injects role prompt + tail" {
  seed_state
  head -c 300000 /dev/zero | tr '\0' 'y' >> "$STATE/master-notes.md"
  echo "NOTES-CANARY-HUGE-BOTTOM" >> "$STATE/master-notes.md"
  run_ss compact new5
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$ctx" == "You are the ORCHESTRATOR"* ]]
  [[ "$ctx" == *"NOTES-CANARY-HUGE-BOTTOM"* ]]
}

@test "A1: chained operator status line has spinner glyphs scrubbed" {
  mkdir -p "$HOME/.claude"
  printf '#!/usr/bin/env bash\necho "a ✻ b ✳ c é"\n' > "$BATS_TEST_TMPDIR/userbar.sh"
  chmod +x "$BATS_TEST_TMPDIR/userbar.sh"
  jq -n --arg c "$BATS_TEST_TMPDIR/userbar.sh" '{statusLine:{type:"command",command:$c}}' > "$HOME/.claude/settings.json"
  run bash -c 'printf "%s" "{}" | "$1"' _ "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a * b * c é"* ]]
}

@test "A3: SessionStart on startup records the session id but emits no context" {
  seed_state
  run_ss startup new2
  [ "$status" -eq 0 ]
  [[ "$output" != *"additionalContext"* ]]
  [ "$(jq -r .session_id "$STATE/master-session.json")" = "new2" ]
}

@test "A3: SessionStart exits 0 and stays valid when rehydrate.sh fails" {
  seed_state
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$ORCH_ROOT/_orch/rehydrate.sh"
  run_ss clear new3
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("You are the ORCHESTRATOR")' >/dev/null
}

# ---------------------------------------------------------------- A4
@test "A4: launch line carries the autocompact window and --settings" {
  jq '.master_context={autocompact_window:400000}' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$ORCH_ROOT/_orch/config.json"
  run "$ORCH_ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  grep -F 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000' "$TMUX_LOG"
  grep -F -- "--settings $STATE/master-settings.json" "$TMUX_LOG"
  jq -e '.statusLine.command | endswith("master-statusline.sh")' "$STATE/master-settings.json"
  jq -e '.hooks.SessionStart[0].hooks[0].command | endswith("master-session-start.sh")' "$STATE/master-settings.json"
}

@test "A4: absent or invalid window omits the env var and bootstrap still succeeds" {
  run "$ORCH_ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  grep -F -- '--settings' "$TMUX_LOG"
  refute_grep_in_existing 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TMUX_LOG"
  for bad in '"400k"' 50 2000000; do
    : > "$TMUX_LOG"
    jq --argjson v "$bad" '.master_context={autocompact_window:$v}' "$ORCH_ROOT/_orch/config.json" > "$BATS_TEST_TMPDIR/c.json"
    mv "$BATS_TEST_TMPDIR/c.json" "$ORCH_ROOT/_orch/config.json"
    run "$ORCH_ROOT/_orch/bootstrap.sh"
    [ "$status" -eq 0 ]
    refute_grep_in_existing 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$TMUX_LOG"
    grep -q 'autocompact_window' "$STATE/orch.log"
  done
}

# ---------------------------------------------------------------- A5
@test "A5: worker settings carry neither statusLine nor SessionStart" {
  : > "$TMUX_LOG.up"   # spawn needs the (stubbed) session to exist
  run "$ORCH_ROOT/_orch/spawn.sh" w1 sonnet "do it"
  [ "$status" -eq 0 ]
  run "$ORCH_ROOT/_orch/spawn.sh" w2 sonnet "do it" --no-worktree
  [ "$status" -eq 0 ]
  wt="$(ORCH_ROOT="$ORCH_ROOT" bash -c 'source "$1/_orch/lib.sh"; worker_wdir "$2" w1' _ "$ORCH_ROOT" "$PROJECT_ROOT")"
  [ -f "$wt/.claude/settings.local.json" ]
  [ -f "$STATE/settings/w2.json" ]
  for f in "$wt/.claude/settings.local.json" "$STATE/settings/w2.json"; do
    refute_grep_in_existing 'statusLine' "$f"
    refute_grep_in_existing 'SessionStart' "$f"
  done
}

@test "A5: orch clean master leaves master-settings.json alone" {
  run "$ORCH_ROOT/_orch/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ -f "$STATE/master-settings.json" ]
  run "$ORCH_ROOT/_orch/clean.sh" master
  [ "$status" -eq 0 ]
  [ -f "$STATE/master-settings.json" ]
}

# ---------------------------------------------------------------- pin
@test "hooks write to their own toolkit's state, not an inherited ORCH_ROOT" {
  other="$BATS_TEST_TMPDIR/other"; mkdir -p "$other/_orch/state"
  run bash -c 'printf "{\"source\":\"startup\",\"session_id\":\"pin1\"}" | ORCH_ROOT="$1" "$2"' _ "$other" "$SS"
  [ "$status" -eq 0 ]
  [ "$(jq -r .session_id "$STATE/master-session.json")" = "pin1" ]
  [ ! -e "$other/_orch/state/master-session.json" ]
  in='{"session_id":"pin2","context_window":{"used_percentage":5,"total_input_tokens":5,"context_window_size":1000000}}'
  run bash -c 'printf "%s" "$1" | ORCH_ROOT="$2" "$3"' _ "$in" "$other" "$SL"
  [ "$status" -eq 0 ]
  [ "$(jq -r .session_id "$STATE/master-context.json")" = "pin2" ]
  [ ! -e "$other/_orch/state/master-context.json" ]
}

@test "A1: tokens come from current_usage (context now), not cumulative total_input_tokens" {
  in='{"session_id":"s1","context_window":{"used_percentage":30,"total_input_tokens":999999,"context_window_size":200000,"current_usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":59890}}}'
  run bash -c 'printf "%s" "$1" | "$2"' _ "$in" "$SL"
  [ "$status" -eq 0 ]
  [ "$(jq '.tokens' "$STATE/master-context.json")" = "60000" ]
}

@test "A2: chained operator status line cannot match TUI_BUSY_REGEX" {
  mkdir -p "$HOME/.claude"
  printf '#!/usr/bin/env bash\necho "Running… compacting ESC TO INTERRUPT"\n' > "$BATS_TEST_TMPDIR/userbar.sh"
  chmod +x "$BATS_TEST_TMPDIR/userbar.sh"
  jq -n --arg c "$BATS_TEST_TMPDIR/userbar.sh" '{statusLine:{type:"command",command:$c}}' > "$HOME/.claude/settings.json"
  run bash -c 'printf "%s" "{}" | "$1"' _ "$SL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running"* ]]
  run bash -c 'printf "%s" "$1" | grep -ciE "esc to interrupt|Running…|Compacting"' _ "$output"
  [ "$output" = "0" ]
}
