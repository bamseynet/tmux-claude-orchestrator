#!/usr/bin/env bats
# Hermetic tests for issue #185: spawn's own .claude/settings.local.json must not
# make the worktree dirty, so a same-id respawn is not refused by the #37 guard
# on hosts without a global git ignore.

setup() {
  unset ORCH_ROOT SESSION_NAME ORCH_BASE_BRANCH
  # Host git config must not leak in (the bug's root): empty HOME/XDG, no system config.
  export HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  list-sessions) echo "$SESSION_NAME" ;;\n  list-windows) exit 0 ;;\n  capture-pane) echo "> ready for shortcuts" ;;\nesac\nexit 0\n' > "$STUBBIN/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"
  SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/_orch/state/workers"
  cat > "$ROOT/_orch/config.json" <<'JSON'
{
  "thresholds": { "max_workers": 4, "min_free_mb": 0, "est_worker_mb": 0 },
  "budget": { "enabled": false, "max_usd": 5.0, "est_usd_per_worker": 0.5 }
}
JSON
  PROJECT_ROOT="$BATS_TEST_TMPDIR/proj"
  git init -q -b main "$PROJECT_ROOT"
  git -C "$PROJECT_ROOT" config user.email t@example.com
  git -C "$PROJECT_ROOT" config user.name t
  echo hi > "$PROJECT_ROOT/f.txt"   # deliberately NO .gitignore
  git -C "$PROJECT_ROOT" add f.txt
  git -C "$PROJECT_ROOT" commit -q -m init
  export PROJECT_ROOT ORCH_ROOT="$ROOT" SESSION_NAME=nosuch ORCH_ALLOW_UNRELATED_REPO=1
  WDIR=""
}

_wdir() { bash -c 'source "'"$BATS_TEST_DIRNAME"'/../_orch/lib.sh"; worker_wdir "$PROJECT_ROOT" w1'; }

_first_spawn() {
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 0 ]
  WDIR="$(_wdir)"
  f="$ROOT/_orch/state/workers/w1.json"
  jq '.status="done"' "$f" > "$f.x" && mv "$f.x" "$f"
}

@test "reuse works: respawn of a done worker with no global ignore" {
  _first_spawn
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 0 ]
  grep -q "already a clean worktree .* reusing" "$ROOT/_orch/state/orch.log"
}

@test "worktree is clean after spawn and add -A stages nothing" {
  _first_spawn
  [ -f "$WDIR/.claude/settings.local.json" ]
  [ -z "$(git -C "$WDIR" status --porcelain)" ]
  [ -z "$(git -C "$WDIR" add -A --dry-run)" ]
}

@test "real dirt still refused: untracked root file" {
  _first_spawn
  echo x > "$WDIR/foo.txt"
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 1 ]
  [[ "$output" == *spawn-failed* ]]
}

@test "real dirt still refused: untracked .claude/other.json" {
  _first_spawn
  echo '{}' > "$WDIR/.claude/other.json"
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 1 ]
  [[ "$output" == *spawn-failed* ]]
}

@test "real dirt still refused: modified tracked file" {
  _first_spawn
  echo more >> "$WDIR/f.txt"
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 1 ]
  [[ "$output" == *spawn-failed* ]]
}

@test "real dirt still refused: staged change" {
  _first_spawn
  echo more >> "$WDIR/f.txt"; git -C "$WDIR" add f.txt
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 1 ]
  [[ "$output" == *spawn-failed* ]]
}

@test "changed settings.local.json does not block reuse" {
  _first_spawn
  echo '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$WDIR/.claude/settings.local.json"
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 0 ]
  grep -q "already a clean worktree .* reusing" "$ROOT/_orch/state/orch.log"
}

@test "main checkout and shared git state untouched across two spawns" {
  before="$(git -C "$PROJECT_ROOT" status --porcelain)"
  _first_spawn
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 0 ]
  [ "$(git -C "$PROJECT_ROOT" status --porcelain)" = "$before" ]
  [ ! -e "$PROJECT_ROOT/.git/info/exclude" ] || ! grep -q settings.local "$PROJECT_ROOT/.git/info/exclude"
  [ ! -e "$PROJECT_ROOT/.claude" ]
}

@test "a tracked .claude/.gitignore is not overwritten" {
  mkdir -p "$PROJECT_ROOT/.claude"
  echo 'mine' > "$PROJECT_ROOT/.claude/.gitignore"
  git -C "$PROJECT_ROOT" add -f .claude/.gitignore
  git -C "$PROJECT_ROOT" commit -q -m gi
  run "$SPAWN" w1 sonnet t
  [ "$status" -eq 0 ]
  [ "$(cat "$(_wdir)/.claude/.gitignore")" = mine ]
  # The tracked file does not cover settings.local.json: spawn must say so.
  grep -q "settings.local.json is not git-ignored" "$ROOT/_orch/state/orch.log"
}

@test "no not-ignored warning when spawn's own .gitignore applies" {
  _first_spawn
  ! grep -q "is not git-ignored" "$ROOT/_orch/state/orch.log"
}
