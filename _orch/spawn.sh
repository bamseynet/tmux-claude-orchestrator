#!/usr/bin/env bash
# _orch/spawn.sh <id> <model> "<task>" [--no-worktree] [--continue | --resume <session-id>]
# Creates an isolated worker: new git worktree, new tmux window, a full Claude Code
# session with report hooks wired back to the orchestrator, then injects the task.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?usage: spawn.sh <id> <model:opus|sonnet|haiku> "<task>" [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd" | --accept-edits | --yolo]}"
model="${2:?model required}"
task="${3:?task prompt required}"
mode=""
resume=""        # optional claude resume flag: "--continue" or "--resume <session-id>"
allow_csv=""     # --allow "cmd,cmd,..." -> permissions.allow in settings.local.json
perm_flag=""     # extra flag(s) on the `claude` launch (acceptEdits / skip-permissions)
# optional flags after the task, any order:
#   [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd" | --accept-edits | --yolo]
args=("${@:4}"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --no-worktree)  mode="--no-worktree" ;;
    --continue)     resume="--continue" ;;
    --resume)       i=$((i+1)); resume="--resume ${args[$i]:?--resume needs a <session-id>}" ;;
    --allow)        i=$((i+1)); allow_csv="${args[$i]:?--allow needs a \"cmd,cmd\" list}" ;;
    --accept-edits) perm_flag="--permission-mode acceptEdits" ;;
    --yolo|--auto)  perm_flag="--dangerously-skip-permissions" ;;
    *) echo "spawn: unknown flag '${args[$i]}'" >&2; exit 1 ;;
  esac
  i=$((i+1))
done
# Claude keys sessions by project dir, so a resumed worker must run in that dir.
if [ -n "$resume" ] && [ "$mode" != "--no-worktree" ]; then
  mode="--no-worktree"
  log "resume requested -> forcing --no-worktree (Claude keys sessions by project dir)"
fi

S="$SESSION_NAME"
proj="${PROJECT_ROOT:-$(pwd)}"

# refuse duplicate window
if tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  echo "worker '$id' already exists in session '$S'"; exit 1
fi

# 1) working directory: isolated worktree (default) or the project root
if [ "$mode" = "--no-worktree" ]; then
  wdir="$proj"
else
  wdir="$proj/../wt/$id"
  if ! git -C "$proj" worktree add -B "orch/$id" "$wdir" >/dev/null 2>&1; then
    log "worktree add failed/exists for $id; reusing $wdir"
  fi
fi
mkdir -p "$wdir/.claude"

# 2) per-worker settings.local.json: report hooks -> orchestrator (always),
#    merged with an optional permissions.allow block when --allow is given.
#    (absolute paths; local file is gitignored)
jq -n --arg r "$here/report.sh" --arg id "$id" --arg allow "$allow_csv" '
  {
    hooks: {
      Stop:         [{hooks:[{type:"command", command:"\($r) \($id) done"}]}],
      Notification: [{hooks:[{type:"command", command:"\($r) \($id) needs-input"}]}],
      SubagentStop: [{hooks:[{type:"command", command:"\($r) \($id) subagent-done"}]}]
    }
  }
  + (if $allow == "" then {}
     else {permissions: {allow: ($allow | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}}
     end)
' > "$wdir/.claude/settings.local.json"

# 3) initial status file
jq -Rn --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$(date -u +%FT%TZ)" \
  '{id:$id, status:"spawning", model:$m, task:$t, updated:$u}' > "$WORKERS_DIR/$id.json"

# 4) new window + launch a full Claude Code session
# (append after the last window; bare `-t "$S"` can fail with "index 0 in use"
#  on base-index 0 sessions, so target an explicit end-of-session slot)
tmux new-window -a -t "$S:{end}" -n "$id" -c "$wdir"
tmux set-window-option -t "$S:$id" monitor-activity on
tmux send-keys -t "$S:$id" "ORCH_WORKER_ID=$id ORCH_DIR='$here' claude${resume:+ $resume}${perm_flag:+ $perm_flag}" Enter

# 5) wait for the REPL, then set the model
if wait_ready "$S:$id" 60; then
  send_prompt "$S:$id" "/$model"
  wait_ready "$S:$id" 20 || true
else
  log "worker $id not ready in 60s; sending task anyway"
fi

# 6) inject the task
send_prompt "$S:$id" "$task"
jq '.status="working"' "$WORKERS_DIR/$id.json" > "$WORKERS_DIR/$id.json.tmp" \
  && mv "$WORKERS_DIR/$id.json.tmp" "$WORKERS_DIR/$id.json"

log "spawned $id ($model) in $wdir"
echo "spawned $id ($model)  ->  window $S:$id   dir $wdir"
