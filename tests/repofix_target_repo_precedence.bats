#!/usr/bin/env bats
# Follow-up to issue #35: config.json's .target_repo must be honored above cwd
# when resolving the spawn target repo, with no $PROJECT_ROOT/$ORCH_TARGET_REPO/
# --repo set. This exercises the FULL `./orch spawn` path end-to-end (not just
# `./orch status`, which repotarget_config.bats already covers) against a real,
# throwaway copy of the toolkit + a real target repo, so a regression in the
# precedence order shows up as a worktree created in the wrong repo.
#
# tmux and claude are stubbed; git stays real so `git worktree add`/`git -C`
# semantics are exercised for real. No real tmux window or claude process runs.

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/toolkit" "$WORK/target" "$WORK/othercwd" "$WORK/bin"

  cp -r "$BATS_TEST_DIRNAME/../_orch" "$WORK/toolkit/_orch"
  cp "$BATS_TEST_DIRNAME/../orch" "$WORK/toolkit/orch"
  chmod +x "$WORK/toolkit/orch"

  git init -q "$WORK/toolkit"
  git -C "$WORK/toolkit" config user.email test@example.com
  git -C "$WORK/toolkit" config user.name test
  git -C "$WORK/toolkit" add -A
  git -C "$WORK/toolkit" commit -q -m init

  # othercwd: NOT a git repo at all, and unrelated to toolkit/target — proves any
  # worktree that lands here (or gets created against it) came from the wrong
  # resolution, since it can't be a git worktree target in the first place.
  :> "$WORK/othercwd/.keep"

  git init -q "$WORK/target"
  git -C "$WORK/target" config user.email test@example.com
  git -C "$WORK/target" config user.name test
  echo hello > "$WORK/target/f.txt"
  git -C "$WORK/target" add f.txt
  git -C "$WORK/target" commit -q -m init

  jq --arg t "$WORK/target" '.target_repo = $t' "$WORK/toolkit/_orch/config.json" \
    > "$WORK/toolkit/_orch/config.json.tmp"
  mv "$WORK/toolkit/_orch/config.json.tmp" "$WORK/toolkit/_orch/config.json"

  cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
esac
exit 0
EOF
  cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"

  PATH="$WORK/bin:$PATH"
  export PATH WORK

  # `orch` only falls back to its own script location for ORCH_ROOT when the var
  # isn't already set ("${ORCH_ROOT:-$here}") — a worker's shell can inherit
  # ORCH_ROOT from its own launch env, pointing at the PARENT orchestrator's real
  # toolkit. Pin it explicitly to this throwaway copy so state (and the config.json
  # this test edits) always resolves here, never the live toolkit (issue #68).
  export ORCH_ROOT="$WORK/toolkit"
}

@test "orch spawn honors .target_repo from config.json over cwd when PROJECT_ROOT/ORCH_TARGET_REPO/--repo are all absent" {
  cd "$WORK/othercwd"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO=1 \
    "$WORK/toolkit/orch" spawn w1 sonnet "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned w1"* ]]

  # The worktree must be registered against the CONFIGURED target repo, not cwd.
  branch="$(ORCH_ROOT="$WORK/toolkit" bash -c 'source "'"$WORK"'/toolkit/_orch/lib.sh"; worker_branch w1')"
  run git -C "$WORK/target" worktree list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$branch"* ]]

  # cwd (othercwd) was never a git repo and must stay that way — nothing should
  # have been created there.
  run git -C "$WORK/othercwd" rev-parse --show-toplevel
  [ "$status" -ne 0 ]
}

@test "orch spawn still refuses via the relatedness guard when config target_repo is unrelated to the toolkit" {
  cd "$WORK/othercwd"
  run env -u PROJECT_ROOT -u ORCH_TARGET_REPO "$WORK/toolkit/orch" spawn w2 sonnet "do the thing"
  [ "$status" -ne 0 ]
  [[ "$output" == *"look unrelated"* ]]
}
