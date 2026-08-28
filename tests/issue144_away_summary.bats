#!/usr/bin/env bats
# Hermetic tests for issue #144: suppress Claude Code's session recap
# (awaySummaryEnabled) at every claude launch this toolkit performs. See
# issue #144 for the verified mechanism (binary + live confirmed). Modelled
# on tests/issue140_prompt_suggestion_env.bats, whose own assertions this
# file must not regress (A5).
#
# tmux/git/claude are stubbed; no real tmux window, git worktree, or `claude`
# process is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"
TEMPLATE="$BATS_TEST_DIRNAME/../_orch/worker-settings.template.json"

# Shared absence-assertion helpers (issue #134): a bare `! grep` mid-@test is
# exempt from set -e and asserts nothing. Use refute_grep_in_existing, a plain
# command whose non-zero status bats does catch.
source "$BATS_TEST_DIRNAME/helpers/refute.bash"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"
  export CALLS
  : > "$CALLS"

  cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo "orch" ;;
  has-session)   exit 1 ;;
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
  show-buffer)   exit 1 ;;
esac
exit 0
EOF

  cat > "$STUBBIN/git" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
[ "${args[0]:-}" = "-C" ] && i=2
if [ "${args[$i]:-}" = "worktree" ] && [ "${args[$((i+1))]:-}" = "add" ]; then
  mkdir -p "${args[$((${#args[@]}-1))]}"
fi
exit 0
EOF

  cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$STUBBIN/tmux" "$STUBBIN/git" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  export SESSION_NAME="orch"
  mkdir -p "$PROJECT_ROOT" "$ORCH_ROOT/_orch"
  cat > "$ORCH_ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON

  # --- bootstrap.sh fixture: throwaway toolkit copy, background loops stubbed out ---
  TOOLKIT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$TOOLKIT/_orch"
  cp "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh" "$TOOLKIT/_orch/bootstrap.sh"
  cp "$BATS_TEST_DIRNAME/../_orch/lib.sh" "$TOOLKIT/_orch/lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/heartbeat.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLKIT/_orch/watchdog.sh"
  chmod +x "$TOOLKIT/_orch/bootstrap.sh" "$TOOLKIT/_orch/heartbeat.sh" "$TOOLKIT/_orch/watchdog.sh"
  jq -n '{watchdog:{enabled:false}}' > "$TOOLKIT/_orch/config.json"
  BOOTSTRAP="$TOOLKIT/_orch/bootstrap.sh"
  export BOOTSTRAP TOOLKIT
}

@test "A1: worker worktree-mode settings.local.json has awaySummaryEnabled false" {
  run "$SPAWN" w1 sonnet "do the thing"
  [ "$status" -eq 0 ]

  # worktree mode: settings live under the worker's own worktree; locate it via
  # CALLS' tmux `new-window -c` argument instead of guessing the layout.
  wdir_line="$(grep -F 'new-window' "$CALLS" | head -1)"
  wdir="$(printf '%s' "$wdir_line" | sed -n "s/.*-c \\([^ ]*\\).*/\\1/p")"
  [ -n "$wdir" ]
  settings_file="$wdir/.claude/settings.local.json"
  [ -f "$settings_file" ]
  run jq -e '.awaySummaryEnabled == false' "$settings_file"
  [ "$status" -eq 0 ]
}

@test "A2: worker --no-worktree settings JSON has awaySummaryEnabled false and launch carries --settings" {
  run "$SPAWN" w2 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  settings_file="$ORCH_ROOT/_orch/state/settings/w2.json"
  [ -f "$settings_file" ]
  run jq -e '.awaySummaryEnabled == false' "$settings_file"
  [ "$status" -eq 0 ]

  run grep -F -- "--settings '$settings_file'" "$CALLS"
  [ "$status" -eq 0 ]
}

@test "A3: hooks and permissions.allow survive alongside the new key" {
  run "$SPAWN" w3 sonnet "do the thing" --no-worktree --allow "git,gh"
  [ "$status" -eq 0 ]

  settings_file="$ORCH_ROOT/_orch/state/settings/w3.json"
  run jq -e '.hooks.Stop[0].hooks[0].command | test("report\\.sh w3 done$")' "$settings_file"
  [ "$status" -eq 0 ]
  run jq -e '.hooks.Notification[0].hooks[0].command | test("report\\.sh w3 needs-input$")' "$settings_file"
  [ "$status" -eq 0 ]
  run jq -e '.hooks.SubagentStop[0].hooks[0].command | test("report\\.sh w3 subagent-done$")' "$settings_file"
  [ "$status" -eq 0 ]
  run jq -e '.permissions.allow | index("Bash(git:*)") != null' "$settings_file"
  [ "$status" -eq 0 ]
  run jq -e '.awaySummaryEnabled == false' "$settings_file"
  [ "$status" -eq 0 ]
}

@test "A4: bootstrap.sh master launch line carries CLAUDE_CODE_ENABLE_AWAY_SUMMARY=false" {
  run env ORCH_ROOT="$TOOLKIT" PROJECT_ROOT="$PROJECT_ROOT" SESSION_NAME="orch_master_test144" "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  run grep -F 'CLAUDE_CODE_ENABLE_AWAY_SUMMARY=false' "$CALLS"
  [ "$status" -eq 0 ]
}

@test "A5: both env vars coexist on both launch lines (no swap regression)" {
  run "$SPAWN" w4 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  run env ORCH_ROOT="$TOOLKIT" PROJECT_ROOT="$PROJECT_ROOT" SESSION_NAME="orch_master_test144b" "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  run grep -F 'CLAUDE_CODE_ENABLE_AWAY_SUMMARY=false CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model sonnet' "$CALLS"
  [ "$status" -eq 0 ]
  run grep -F 'CLAUDE_CODE_ENABLE_AWAY_SUMMARY=false CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' "$CALLS"
  [ "$status" -eq 0 ]
}

@test "A6: worker-settings.template.json mirrors awaySummaryEnabled false" {
  run jq -e '.awaySummaryEnabled == false' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "A7/A8: no CLI-flag route or claude --help compat probe introduced" {
  refute_grep_in_existing '--away-summary' "$SPAWN"
  refute_grep_in_existing '--away-summary' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing '--away-summary' "$LIB"
  refute_grep_in_existing '--session-recap' "$SPAWN"
  refute_grep_in_existing '--session-recap' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing '--session-recap' "$LIB"
  refute_grep_in_existing '--no-recap' "$SPAWN"
  refute_grep_in_existing '--no-recap' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing '--no-recap' "$LIB"
  refute_grep_in_existing 'claude.*--help' "$SPAWN"
  refute_grep_in_existing 'claude.*--help' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing 'claude.*--help' "$LIB"
}
