#!/usr/bin/env bats
# Hermetic tests for issue #74: spawn.sh --role <name> resolves a worker's model
# through an optional models.roles matrix in config.json, so the model matches
# the KIND of work (mechanical/research/implement/review/synthesis) instead of
# being retyped (or forgotten, and defaulted to the most expensive model) per
# spawn.
#
# Resolution precedence (highest first): explicit model arg > --role > --preset's
# model > models.default_worker. An unknown --role must fail loudly, listing the
# roles that ARE defined — never silently fall back.
#
# tmux/git/claude are stubbed exactly as in models_spawn.bats; no real window,
# worktree, or claude process is ever launched.

SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"

  cat > "$STUBBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)  exit 0 ;;                       # no existing window with this id
  capture-pane)  echo '> ready for shortcuts' ;;  # always looks idle/ready
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
}

write_config_with_roles() { # <default_worker-or-empty>
  jq -n --arg m "${1:-}" '{
    thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0 },
    budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 },
    models: {
      default_worker: $m,
      roles: {
        mechanical: "haiku",
        research: "sonnet",
        implement: "sonnet",
        review: "opus",
        synthesis: "opus"
      }
    }
  }' > "$ORCH_ROOT/_orch/config.json"
}

write_config_no_roles() { # <default_worker-or-empty>
  jq -n --arg m "${1:-}" '{
    thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0 },
    budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 },
    models: { default_worker: $m }
  }' > "$ORCH_ROOT/_orch/config.json"
}

@test "spawn.sh --role resolves the worker's model via models.roles" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w1 "" "adversarially review the auth diff" --role review --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1 (opus)"* ]]
  run jq -r .model "$ORCH_ROOT/_orch/state/workers/w1.json"
  [ "$output" = "opus" ]
}

@test "spawn.sh an explicit model argument beats --role" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w2 haiku "adversarially review the auth diff" --role review --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w2 (haiku)"* ]]
  run jq -r .model "$ORCH_ROOT/_orch/state/workers/w2.json"
  [ "$output" = "haiku" ]
}

@test "spawn.sh --role naming an undefined role fails loudly and lists defined roles" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w3 "" "do the thing" --role bogus --no-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role 'bogus'"* ]]
  [[ "$output" == *"mechanical"* ]]
  [[ "$output" == *"research"* ]]
  [[ "$output" == *"implement"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"synthesis"* ]]
  [ ! -f "$ORCH_ROOT/_orch/state/workers/w3.json" ]
}

@test "spawn.sh --role fails loudly when models.roles is entirely absent from config" {
  write_config_no_roles "sonnet"
  run "$SPAWN" w4 "" "do the thing" --role review --no-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role 'review'"* ]]
  [ ! -f "$ORCH_ROOT/_orch/state/workers/w4.json" ]
}

@test "spawn.sh with no --role and no roles block is unchanged from prior behavior" {
  write_config_no_roles "haiku"
  run "$SPAWN" w5 "" "do the thing" --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w5 (haiku)"* ]]
}

@test "spawn.sh --role combines with --no-worktree, --allow, and --skip-permissions" {
  write_config_with_roles "sonnet"
  export ORCH_ALLOW_SKIP_PERMISSIONS=1
  run "$SPAWN" w6 "" "fetch and record the latency numbers" \
    --role mechanical --no-worktree --allow "Bash(curl:*)" --skip-permissions
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w6 (haiku)"* ]]

  run jq -c '.permissions.allow' "$ORCH_ROOT/_orch/state/settings/w6.json"
  [[ "$output" == *"Bash(curl:*)"* ]]
}

@test "spawn.sh --role combines with --after (queued, not launched yet)" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w7 "" "reconcile the conflicting evidence" --role synthesis --no-worktree --after w-dep
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn queued: w7 (opus)"* ]]
  run jq -r .status "$ORCH_ROOT/_orch/state/workers/w7.json"
  [ "$output" = "queued" ]
  run jq -r .model "$ORCH_ROOT/_orch/state/workers/w7.json"
  [ "$output" = "opus" ]
}

@test "spawn.sh --preset review resolves its model through models.roles when defined" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w8 --preset review --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w8 (opus)"* ]]
}

@test "spawn.sh --preset falls back to its hardcoded model when models.roles has no match" {
  write_config_no_roles "sonnet"
  run "$SPAWN" w9 --preset review --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w9 (sonnet)"* ]]
}

@test "spawn.sh --role overrides even a role-matrix-resolved --preset model" {
  write_config_with_roles "sonnet"
  run "$SPAWN" w10 --preset docs --role synthesis --no-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w10 (opus)"* ]]
}
