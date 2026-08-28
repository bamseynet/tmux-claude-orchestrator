#!/usr/bin/env bats
# Hermetic tests for issue #140: both claude launch sites (worker spawn and
# master bootstrap) must set CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false in their
# env prefix. This is the empirically-verified mechanism (see issue #140) --
# the earlier `--prompt-suggestions` flag route was disproved and is forbidden.
#
# tmux/git/claude are stubbed; no real tmux window, git worktree, or `claude`
# process is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"

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

@test "spawn.sh worker launch line carries CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false in the env prefix" {
  run "$SPAWN" w1 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  run grep -F 'ORCH_WORKER_ID=w1 ORCH_DIR=' "$CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model sonnet"* ]]
}

@test "bootstrap.sh master launch line carries CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false in the env prefix" {
  run env ORCH_ROOT="$TOOLKIT" PROJECT_ROOT="$PROJECT_ROOT" SESSION_NAME="orch_master_test" "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  run grep -F 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' "$CALLS"
  [ "$status" -eq 0 ]
}

@test "no --prompt-suggestions flag or compat probe is introduced on the spawn/bootstrap launch path (issue #140 acceptance)" {
  run "$SPAWN" w2 sonnet "do the thing" --no-worktree
  [ "$status" -eq 0 ]

  run env ORCH_ROOT="$TOOLKIT" PROJECT_ROOT="$PROJECT_ROOT" SESSION_NAME="orch_master_test2" "$BOOTSTRAP"
  [ "$status" -eq 0 ]

  # Acceptance: the flag route was empirically disproved and is forbidden --
  # it must never appear in the composed launch commands...
  refute_grep_in_existing '--prompt-suggestions' "$CALLS"

  # ...nor anywhere in the touched source files (no reintroduction, no probe
  # such as `claude --help` grepped for compatibility). refute_grep_in_existing
  # (plain command, set -e-caught) is used rather than a bare `! grep`, which is
  # inert on every line but the last (issue #134); each of these must be live.
  # lib.sh is included because ORCH_GHOST_ENV -- the single definition both
  # launch sites interpolate -- lives there, so it is now the likeliest place a
  # reintroduction would land.
  refute_grep_in_existing '--prompt-suggestions' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  refute_grep_in_existing '--prompt-suggestions' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing '--prompt-suggestions' "$LIB"
  refute_grep_in_existing 'claude.*--help' "$BATS_TEST_DIRNAME/../_orch/spawn.sh"
  refute_grep_in_existing 'claude.*--help' "$BATS_TEST_DIRNAME/../_orch/bootstrap.sh"
  refute_grep_in_existing 'claude.*--help' "$LIB"
}
