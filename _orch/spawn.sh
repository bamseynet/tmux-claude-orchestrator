#!/usr/bin/env bash
# _orch/spawn.sh <id> <model> "<task>" [--no-worktree] [--continue | --resume <session-id>]
# Creates an isolated worker: new git worktree, new tmux window, a full Claude Code
# session with report hooks wired back to the orchestrator, then injects the task.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?usage: spawn.sh <id> <model:opus|sonnet|haiku> "<task>" [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"]}"
model="${2:?model required}"
task="${3:?task prompt required}"
mode=""
resume=""        # optional claude resume flag: "--continue" or "--resume <session-id>"
allow_csv=""     # --allow "cmd,cmd,..." -> permissions.allow in settings.local.json
# optional flags after the task, any order:
#   [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"]
args=("${@:4}"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --no-worktree)  mode="--no-worktree" ;;
    --continue)     resume="--continue" ;;
    --resume)       i=$((i+1)); resume="--resume ${args[$i]:?--resume needs a <session-id>}" ;;
    --allow)        i=$((i+1)); allow_csv="${args[$i]:?--allow needs a \"cmd,cmd\" list}" ;;
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

# Unified resource guard (issues #21 concurrency, #31 memory, #24 budget): refuse
# to launch another full Claude Code session when any cap is at/over the line, and
# persist the spawn to the pending queue instead. heartbeat.sh drains the queue as
# soon as the gate allows it again (typically once a worker reports "done").
if ! check_spawn_gate; then
  ts="$(date -u +%FT%TZ)"
  queue_item="$(jq -nc --arg id "$id" --arg model "$model" --arg task "$task" --arg mode "$mode" \
        --arg resume "$resume" --arg allow "$allow_csv" --arg ts "$ts" --arg reason "$GATE_REASON" \
    '{id:$id, model:$model, task:$task, mode:$mode, resume:$resume, allow_csv:$allow, ts:$ts, reason:$reason}')"
  queue_push "$queue_item"
  write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$ts" \
    '{id:$id, status:"queued", model:$m, task:$t, updated:$u}'
  log "spawn refused for $id: $GATE_REASON; queued"
  echo "spawn queued: $id ($model) refused — $GATE_REASON"
  exit 0
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
write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$(date -u +%FT%TZ)" \
  '{id:$id, status:"spawning", model:$m, task:$t, updated:$u}'

# 4) new window + launch a full Claude Code session
# (append after the last window; bare `-t "$S"` can fail with "index 0 in use"
#  on base-index 0 sessions, so target an explicit end-of-session slot)
tmux new-window -a -t "$S:{end}" -n "$id" -c "$wdir"
tmux set-window-option -t "$S:$id" monitor-activity on
tmux send-keys -t "$S:$id" "ORCH_WORKER_ID=$id ORCH_DIR='$here' claude --model $model${resume:+ $resume}" Enter

# 5) wait for the REPL to be ready before injecting the task.
#    Model is now set at launch via --model (see #30), so no slash-command dance.
if ! wait_ready "$S:$id" 60; then
  log "worker $id not ready in 60s; sending task anyway"
fi

# 6) inject the task.
#    Guard 2 (anti-skill preamble): shape ONLY the injected prompt so the worker
#    completes the task directly instead of detouring into a skill. It keeps every
#    skill available for later legitimate use — this changes the first message, not
#    the session config.
preamble='[Orchestrated task — complete it directly. Do not invoke any skill unless this task explicitly requires one.] '
send_prompt "$S:$id" "${preamble}${task}"

# Guard 1 (inject verification + retry): a send can land before the REPL is ready
# and be lost, leaving the worker idle at the startup screen so it never fires a
# report hook. Confirm the injection landed (banner scrolled away / pane active);
# re-inject once; if still unconfirmed, mark spawn-failed and notify the master.
# Bounded polling — never hangs.
if confirm_inject "$S:$id" 15; then
  spawn_ok=1
else
  log "worker $id: task injection unconfirmed; re-injecting once"
  send_prompt "$S:$id" "${preamble}${task}"
  if confirm_inject "$S:$id" 15; then spawn_ok=1; else spawn_ok=0; fi
fi

if [ "$spawn_ok" -eq 1 ]; then
  update_worker_status "$id" '.status="working"'
  record_spend
  log "spawned $id ($model) in $wdir"
  echo "spawned $id ($model)  ->  window $S:$id   dir $wdir"
else
  # Never-started worker: record it and tell the master so the spawn is not lost.
  update_worker_status "$id" '.status="spawn-failed"'
  printf '{"id":"%s","event":"spawn-failed","ts":"%s"}\n' "$id" "$(date -u +%FT%TZ)" >> "$INBOX"
  log "worker $id: spawn-failed (task injection unconfirmed after retry)"
  echo "spawn-failed $id ($model)  ->  window $S:$id   dir $wdir" >&2
fi
