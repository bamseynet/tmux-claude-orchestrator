#!/usr/bin/env bats
# Issue #152: a worktree-mode worker must not write into the target repo's main
# checkout. spawn persists wdir/mode in status and installs a PreToolUse hook
# (_orch/guard-write.sh) that denies Edit/Write/MultiEdit/NotebookEdit on a
# path under the target repo but outside the worker's worktree.
#
# Hermetic: scratch git repo, PATH-stubbed tmux/claude, no live session.

ORCH_DIR_SRC="$BATS_TEST_DIRNAME/../_orch"
GUARD="$ORCH_DIR_SRC/guard-write.sh"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) echo "nosuch152" ;;
  list-windows)  exit 0 ;;
  capture-pane)  echo '> ready for shortcuts' ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/claude"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude"
  PATH="$STUBBIN:$PATH"

  R="$BATS_TEST_TMPDIR/r"; mkdir -p "$R"
  export ORCH_ROOT="$R/toolkit" TARGET="$R/target"
  for d in "$ORCH_ROOT" "$TARGET"; do
    git init -q -b main "$d"
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name t
    echo x > "$d/f.txt"; git -C "$d" add f.txt; git -C "$d" commit -q -m init
  done
  mkdir -p "$ORCH_ROOT/_orch"
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' \
    > "$ORCH_ROOT/_orch/config.json"
  export SESSION_NAME="nosuch152"
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO ORCH_ALLOW_UNRELATED_REPO
  WORKERS="$ORCH_ROOT/_orch/state/workers"; mkdir -p "$WORKERS"
}

spawn() { env PROJECT_ROOT="$TARGET" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" "$@"; }

payload() { # <tool> <file_path>
  jq -n --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p}}'
}

hook_cmd() { # <settings-file>
  # a missing hook must not read as an empty (always-passing) command
  jq -r '.hooks.PreToolUse[0].hooks[0].command // "exit 99"' "$1" 2>/dev/null || echo "exit 99"
}

@test "spawn persists wdir and mode in worker status (worktree mode)" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  [ -d "$wdir" ]
  [ "$wdir" != "$TARGET" ]
  [ "$(jq -r .mode "$WORKERS/w1.json")" = "worktree" ]
}

@test "spawn --no-worktree records mode no-worktree and wdir = target" {
  run spawn w2 sonnet "task" --no-worktree
  [ "$status" -eq 0 ]
  [ "$(jq -r .mode "$WORKERS/w2.json")" = "no-worktree" ]
  [ "$(jq -r .wdir "$WORKERS/w2.json")" = "$TARGET" ]
}

@test "worktree worker settings carry a PreToolUse hook on the write tools" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$s")" = "Edit|Write|MultiEdit|NotebookEdit" ]
  [[ "$(hook_cmd "$s")" == *guard-write.sh* ]]
}

@test "hook denies a Write into the target repo root and logs the worker id" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$TARGET/_orch/lib.sh")"
  [ "$status" -eq 2 ]
  [[ "$output" == *w1* ]]
  grep -q '"id":"w1".*"event":"write-outside-worktree"' "$ORCH_ROOT/_orch/state/events.jsonl"
  grep -q "$TARGET/_orch/lib.sh" "$ORCH_ROOT/_orch/state/events.jsonl"
}

@test "hook allows a Write inside the worker's worktree" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/_orch/lib.sh")"
  [ "$status" -eq 0 ]
  ! grep -q write-outside-worktree "$ORCH_ROOT/_orch/state/events.jsonl" 2>/dev/null
}

@test "hook allows paths outside the target repo (scratchpad, /tmp)" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write /tmp/scratch/x.md)"
  [ "$status" -eq 0 ]
}

@test "hook allows a sibling path that merely shares the target prefix" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Edit "${TARGET}-other/x.txt")"
  [ "$status" -eq 0 ]
}

@test "hook denies .. traversal out of the worktree into the target" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/../../../../target/f.txt")"
  [ "$status" -eq 2 ]
}

@test "hook reads notebook_path for NotebookEdit" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(jq -n --arg p "$TARGET/n.ipynb" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}')"
  [ "$status" -eq 2 ]
}

@test "hook fails open on unparseable payload" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"not json"
  [ "$status" -eq 0 ]
}

@test "--no-worktree worker's private settings have no PreToolUse guard" {
  run spawn w2 sonnet "task" --no-worktree
  [ "$status" -eq 0 ]
  s="$ORCH_ROOT/_orch/state/settings/w2.json"
  [ -f "$s" ]
  [ "$(jq -r '.hooks.PreToolUse // "none"' "$s")" = "none" ]
}

@test "reference template mirrors the PreToolUse hook" {
  t="$ORCH_DIR_SRC/worker-settings.template.json"
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$t")" = "Edit|Write|MultiEdit|NotebookEdit" ]
}

@test "adding the PreToolUse guard keeps the Stop/Notification/SubagentStop hooks" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run jq -e '(.hooks | keys | sort) == ["Notification","PreToolUse","Stop","SubagentStop"]' "$s"
  [ "$status" -eq 0 ]
}

@test "hook denies MultiEdit into the target repo" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload MultiEdit "$TARGET/f.txt")"
  [ "$status" -eq 2 ]
}

@test "hook denies a write via the physical path of a symlinked target repo" {
  real="$BATS_TEST_TMPDIR/real"; mkdir -p "$real"
  mv "$TARGET" "$real/target"; ln -s "$real/target" "$TARGET"
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$real/target/f.txt")"
  [ "$status" -eq 2 ]
  # and the worktree's own physical path is still allowed
  wphys="$(cd -P "$(jq -r .wdir "$WORKERS/w1.json")" && pwd -P)"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wphys/new.txt")"
  [ "$status" -eq 0 ]
}

@test "hook does not glob-expand path segments" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  # from inside the worktree, an unguarded glob "*" would expand to its entries
  run bash -c "cd '$wdir' && $(hook_cmd "$s")" <<<"$(payload Write "$TARGET/*")"
  [ "$status" -eq 2 ]
  grep -q "$TARGET/\\*\"" "$ORCH_ROOT/_orch/state/events.jsonl"
}

@test "hook resolves a symlink before .. (no bypass via <link-into-target>/..)" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  mkdir -p "$TARGET/sub" "$BATS_TEST_TMPDIR/elsewhere/in"
  ln -s "$TARGET/sub" "$BATS_TEST_TMPDIR/lnk"
  # physically $TARGET/f.txt; lexically $BATS_TEST_TMPDIR/f.txt
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$BATS_TEST_TMPDIR/lnk/../f.txt")"
  [ "$status" -eq 2 ]
}

@test "hook denies <link-out-of-target>/.. that normalises lexically into the target" {
  run spawn w1 sonnet "task"
  [ "$status" -eq 0 ]
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/in"
  ln -s "$BATS_TEST_TMPDIR/elsewhere/in" "$TARGET/out"
  # physically elsewhere/x.txt, but a writer that normalises the path string first
  # (as the missing-tail test above assumes) writes $TARGET/x.txt: deny either way
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$TARGET/out/../x.txt")"
  [ "$status" -eq 2 ]
}

@test "a denied write is also queued to the inbox for the master" {
  run spawn w1 sonnet "task"
  s="$(jq -r .wdir "$WORKERS/w1.json")/.claude/settings.local.json"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$TARGET/f.txt")"
  [ "$status" -eq 2 ]
  grep -q '"id":"w1","event":"write-outside-worktree"' "$ORCH_ROOT/_orch/state/inbox.jsonl"
}

@test "hook denies a write through a worktree file symlinked into the target" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  ln -s "$TARGET/f.txt" "$wdir/link.txt"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/link.txt")"
  [ "$status" -eq 2 ]
  # a relative link hop resolves against the link's own directory
  ln -s ../../../../target/f.txt "$wdir/rel.txt"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/rel.txt")"
  [ "$status" -eq 2 ]
}

@test "hook re-resolves a symlink reached only after lexical .. in a missing tail" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  ln -s "$TARGET/f.txt" "$wdir/link.txt"
  # "nosuch" does not exist, so the kernel cannot see the link through it; the
  # writer normalises lexically to $wdir/link.txt and writes through into $TARGET
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/nosuch/../link.txt")"
  [ "$status" -eq 2 ]
}

@test "hook follows a dangling directory symlink in the path" {
  run spawn w1 sonnet "task"
  wdir="$(jq -r .wdir "$WORKERS/w1.json")"
  s="$wdir/.claude/settings.local.json"
  ln -s "$TARGET/newdir" "$wdir/dl"
  run bash -c "$(hook_cmd "$s")" <<<"$(payload Write "$wdir/dl/x.txt")"
  [ "$status" -eq 2 ]
}
