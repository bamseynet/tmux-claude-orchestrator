#!/usr/bin/env bash
# _orch/spawn.sh <id> <model> "<task>" [--no-worktree] [--continue | --resume <session-id>] [--role <name>] [--skip-permissions|--yolo]
#   or: _orch/spawn.sh <id> --preset <review|test|docs> [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"] [--role <name>] [--skip-permissions|--yolo]
# Creates an isolated worker: new git worktree, new tmux window, a full Claude Code
# session with report hooks wired back to the orchestrator, then injects the task.
# model may be "" to fall back to models.default_worker in config.json (issue #25).
# --skip-permissions/--yolo (issue #69, opt-in, requires ORCH_ALLOW_SKIP_PERMISSIONS=1):
# launches the worker with --dangerously-skip-permissions, bypassing ALL permission
# checks. Use only for trusted tasks in isolated worktrees.
# --role <name> (issue #74): resolves the worker's model through models.roles.<name>
# in config.json, so the model matches the KIND of work (mechanical/research/implement/
# review/synthesis) instead of being retyped per spawn. Resolution precedence, highest
# first: explicit model arg > --role > --preset's model > models.default_worker. A
# --role naming a role absent from models.roles fails loudly, listing the roles that
# ARE defined — never a silent fallback.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?usage: spawn.sh <id> <model:opus|sonnet|haiku|""> "<task>" [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"] [--after <id>] [--role <name>] [--skip-permissions|--yolo]
   or: spawn.sh <id> --preset <review|test|docs> [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"] [--after <id>] [--role <name>] [--skip-permissions|--yolo]}"
mode=""
resume=""        # optional claude resume flag: "--continue" or "--resume <session-id>"
allow_csv=""     # --allow "cmd,cmd,..." -> permissions.allow in settings.local.json
preset_allow=""  # --allow additions bundled by --preset, merged with any explicit --allow
after_id=""      # --after <id> (issue #22): hold this spawn until worker <id> reaches "done"
skip_perms=""    # --skip-permissions/--yolo (issue #69): launch worker with --dangerously-skip-permissions
role=""          # --role <name> (issue #74): resolved against models.roles.<name>
preset_role=""   # role a --preset maps to, for the models.roles refinement below

# resolve_role <name>: prints the model for models.roles.<name>, or fails loudly
# listing the roles that ARE defined (issue #74) — a silent fallback to an
# expensive default is exactly the bug --role exists to prevent.
resolve_role() {
  local name="$1" m defined
  m="$(jq -r --arg r "$name" '.models.roles[$r] // empty' "$CONFIG" 2>/dev/null)"
  if [ -z "$m" ]; then
    defined="$(jq -r '(.models.roles // {}) | keys | join(", ")' "$CONFIG" 2>/dev/null)"
    if [ -n "$defined" ]; then
      say "spawn: unknown role '$name' (expected one of: $defined)" >&2
    else
      say "spawn: unknown role '$name' (models.roles is not defined in $CONFIG)" >&2
    fi
    exit 1
  fi
  printf '%s' "$m"
}

# --preset review|test|docs (issue #25): a canned model + task + --allow bundle, so a
# common one-off ("review this branch", "get tests green", "sync the docs") is one
# flag instead of retyping the same model/prompt/permissions every time.
if [ "${2:-}" = "--preset" ]; then
  preset="${3:?--preset needs a name: review|test|docs}"
  case "$preset" in
    review)
      model="sonnet"
      preset_role="review"
      task="Review the current branch/diff for correctness, security, and style issues. Report findings; do not fix unless asked."
      preset_allow="Bash(git diff:*),Bash(git log:*),Bash(git show:*)"
      ;;
    test)
      model="sonnet"
      preset_role="implement"
      task="Write and run tests for the recent changes until they are green. Do not modify unrelated code."
      preset_allow="Bash(npm test:*),Bash(pytest:*),Bash(bats tests/*:*)"
      ;;
    docs)
      model="haiku"
      preset_role="mechanical"
      task="Update documentation (README, comments, docstrings) to match the current code. Do not change behavior."
      preset_allow="Bash(git diff:*)"
      ;;
    *) say "spawn: unknown preset '$preset' (expected review|test|docs)" >&2; exit 1 ;;
  esac
  # models.roles refinement (issue #74): when the preset's mapped role IS defined
  # in config, let the matrix be authoritative instead of the hardcoded model
  # above; when it isn't, behavior is unchanged (falls through to the hardcoded
  # model set in the case block).
  refined_model="$(jq -r --arg r "$preset_role" '.models.roles[$r] // empty' "$CONFIG" 2>/dev/null)"
  [ -n "$refined_model" ] && model="$refined_model"
  args=("${@:4}")
  explicit_model=""
else
  explicit_model="${2:-}"  # non-empty means the caller pinned a model explicitly (wins over --role)
  model="$explicit_model"
  task="${3:?task prompt required}"
  args=("${@:4}")
fi
# optional flags after model/task (or after --preset <name>), any order:
#   [--no-worktree] [--continue | --resume <session-id>] [--allow "cmd,cmd"] [--after <id>]
#   [--role <name>] [--skip-permissions | --yolo]
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --no-worktree)  mode="--no-worktree" ;;
    --continue)     resume="--continue" ;;
    --resume)       i=$((i+1)); resume="--resume ${args[$i]:?--resume needs a <session-id>}" ;;
    --allow)        i=$((i+1)); allow_csv="${args[$i]:?--allow needs a \"cmd,cmd\" list}" ;;
    --after)        i=$((i+1)); after_id="${args[$i]:?--after needs a worker <id>}" ;;
    --role)         i=$((i+1)); role="${args[$i]:?--role needs a role name}" ;;
    --skip-permissions|--yolo) skip_perms=1 ;;
    *) say "spawn: unknown flag '${args[$i]}'" >&2; exit 1 ;;
  esac
  i=$((i+1))
done

# Model resolution precedence (issue #74), highest first: an explicit model arg
# (already sitting in $model when $explicit_model is non-empty) always wins;
# else --role via resolve_role(); else --preset's model / models.roles refinement
# above (already sitting in $model); else models.default_worker as a last resort.
if [ -z "$explicit_model" ] && [ -n "$role" ]; then
  model="$(resolve_role "$role")"
fi
if [ -z "$model" ]; then
  model="$(jq -r '.models.default_worker // empty' "$CONFIG" 2>/dev/null)"
  [ -n "$model" ] || { say "spawn: model required (or set models.default_worker in $CONFIG)" >&2; exit 1; }
fi

# Opt-in worker sandbox bypass (issue #69): mirrors how bootstrap.sh launches the
# master with --dangerously-skip-permissions, but per-spawn and strictly opt-in —
# the default stays gated. A second env acknowledgement is required so this can
# never be enabled by accident (e.g. a stray flag in a copy-pasted command).
if [ -n "$skip_perms" ] && [ "${ORCH_ALLOW_SKIP_PERMISSIONS:-}" != "1" ]; then
  say "spawn: --skip-permissions/--yolo requires ORCH_ALLOW_SKIP_PERMISSIONS=1 in the environment." >&2
  say "This bypasses ALL permission checks for worker '$id' — trusted tasks in isolated worktrees only." >&2
  say "Set ORCH_ALLOW_SKIP_PERMISSIONS=1 to acknowledge and re-run." >&2
  exit 1
fi

if [ -n "$preset_allow" ]; then
  allow_csv="${allow_csv:+$allow_csv,}$preset_allow"
fi

# Claude keys sessions by project dir, so a resumed worker must run in that dir.
if [ -n "$resume" ] && [ "$mode" != "--no-worktree" ]; then
  mode="--no-worktree"
  log "resume requested -> forcing --no-worktree (Claude keys sessions by project dir)"
fi

S="$SESSION_NAME"

# --- target-repo resolution fallback (issue #47) ------------------------------------
# `./orch` resolves the target repo (--repo > $PROJECT_ROOT > $ORCH_TARGET_REPO >
# .target_repo in config.json > cwd) and exports PROJECT_ROOT before exec'ing this
# script. If spawn.sh is ever invoked directly instead of via `./orch spawn`, mirror
# the same precedence here (minus --repo, which is an ./orch-only flag) so the
# config-file/env-var levels are never silently skipped in favor of cwd.
_resolve_target_repo() {
  if [ -n "${PROJECT_ROOT:-}" ]; then
    printf '%s' "$PROJECT_ROOT"; return
  fi
  if [ -n "${ORCH_TARGET_REPO:-}" ]; then
    printf '%s' "$ORCH_TARGET_REPO"; return
  fi
  local cfg_target
  cfg_target="$(jq -r '.target_repo // empty' "$CONFIG" 2>/dev/null || true)"
  if [ -n "$cfg_target" ]; then
    case "$cfg_target" in
      /*) printf '%s' "$cfg_target" ;;
      *) printf '%s' "$ORCH_ROOT/$cfg_target" ;;
    esac
    return
  fi
  pwd
}

proj="$(_resolve_target_repo)"
proj="$(cd "$proj" 2>/dev/null && pwd)" || {
  say "spawn: target repo path does not exist: $proj" >&2
  exit 1
}

# Guard 0 (issue #35): the toolkit dir and target repo must be provably related
# before we create anything against $proj — see ensure_related_repo() in lib.sh.
if ! ensure_related_repo "$ORCH_ROOT" "$proj"; then
  log "spawn refused for $id: toolkit dir ($ORCH_ROOT) and target repo ($proj) look unrelated"
  say "orch: toolkit dir ($ORCH_ROOT) and target repo ($proj) look unrelated (no shared git history or remote)." >&2
  say "Set _orch/config.json's target_repo, ORCH_TARGET_REPO, or --repo explicitly if this is intentional," >&2
  say "or set ORCH_ALLOW_UNRELATED_REPO=1 to override." >&2
  exit 1
fi

# refuse duplicate window
if tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  say "worker '$id' already exists in session '$S'"; exit 1
fi

# Task dependencies (issue #22): --after <id> holds this spawn in the pending
# queue unconditionally — never attempt to launch now, regardless of the resource
# gate — until worker <id> reaches status "done". heartbeat.sh's drain_queue_if_room
# already scans the queue every tick and launches whatever is ready; it just also
# needs to skip an item whose dependency has not finished yet, so `after` rides
# along in the same queue record and worker-status file the gate-refusal path
# below already uses for its own no-slot-available case.
if [ -n "$after_id" ]; then
  ts="$(date -u +%FT%TZ)"
  queue_item="$(jq -nc --arg id "$id" --arg model "$model" --arg task "$task" --arg mode "$mode" \
        --arg resume "$resume" --arg allow "$allow_csv" --arg ts "$ts" \
        --arg reason "waiting for dependency '$after_id' to reach done" --arg after "$after_id" \
    '{id:$id, model:$model, task:$task, mode:$mode, resume:$resume, allow_csv:$allow, ts:$ts, reason:$reason, after:$after}')"
  queue_push "$queue_item"
  # shellcheck disable=SC2016  # jq filter in single quotes; $id/$m/$t/$u/$a are jq --arg vars, not shell
  write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$ts" --arg a "$after_id" \
    '{id:$id, status:"queued", model:$m, task:$t, created:$u, updated:$u, after:$a}'
  log "spawn queued for $id: waiting for dependency $after_id to reach done"
  say "spawn queued: $id ($model) waiting on '$after_id' to reach done"
  exit 0
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
  # shellcheck disable=SC2016  # jq filter in single quotes; $id/$m/$t/$u are jq --arg vars, not shell
  write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$ts" \
    '{id:$id, status:"queued", model:$m, task:$t, created:$u, updated:$u}'
  log "spawn refused for $id: $GATE_REASON; queued"
  say "spawn queued: $id ($model) refused — $GATE_REASON"
  exit 0
fi

# 1) working directory: isolated worktree (default) or the project root
if [ "$mode" = "--no-worktree" ]; then
  wdir="$proj"
else
  # Namespaced per install (issue #86): $proj/../wt/<hash-of-ORCH_ROOT>/<id> on
  # branch orch/<hash>/<id>, so two orch installs targeting the same repo never
  # want the same path/branch for the same worker id.
  wdir="$(worker_wdir "$proj" "$id")"
  branch="$(worker_branch "$id")"
  # Guard (issue #37): a pre-existing path at $wdir must not be silently reused
  # just because `worktree add` failed on it. Decide deterministically instead:
  # reuse only if it is verifiably a clean worktree of THIS repo on $branch AND
  # owned by THIS install (issue #86); otherwise fail loudly rather than run the
  # worker against an unknown or foreign-owned tree.
  if [ -e "$wdir" ]; then
    if worktree_owned_by_other "$wdir"; then
      owner="$(worktree_owner "$wdir")"
      log "spawn refused for $id: $wdir is owned by a different orch install ($owner)"
      update_worker_status "$id" '.status="spawn-failed"'
      sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
      printf '%s\n' "$sf_line" >> "$INBOX"
      printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
      say "spawn-failed $id: $wdir is owned by a different orch install ($owner), not this one ($ORCH_ROOT)." >&2
      say "Use a different id, or clean it up from that install." >&2
      exit 1
    elif worktree_matches_expected "$proj" "$wdir" "$branch"; then
      log "worktree add: $wdir already a clean worktree of $proj on $branch; reusing"
      stamp_worktree_owner "$wdir" || true
    else
      log "spawn refused for $id: $wdir exists and is not a clean worktree of $proj on $branch"
      update_worker_status "$id" '.status="spawn-failed"'
      sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
      printf '%s\n' "$sf_line" >> "$INBOX"
      printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
      say "spawn-failed $id: $wdir exists and is not a valid worktree for this repo/branch." >&2
      say "Run 'orch clean $id' to remove it, or use a different id." >&2
      exit 1
    fi
  elif ! git -C "$proj" worktree add -B "$branch" "$wdir" >/dev/null 2>&1; then
    log "spawn refused for $id: git worktree add failed for $wdir"
    update_worker_status "$id" '.status="spawn-failed"'
    sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
    printf '%s\n' "$sf_line" >> "$INBOX"
    printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
    say "spawn-failed $id: git worktree add failed for $wdir" >&2
    exit 1
  else
    stamp_worktree_owner "$wdir" || true
  fi
fi
# 2) per-worker settings: report hooks -> orchestrator (always), merged with an
#    optional permissions.allow block when --allow is given.
#
#    Issue #43: for --no-worktree, $wdir IS the shared target-repo root, so
#    writing this worker's hooks into <wdir>/.claude/settings.local.json would
#    leak into every git-worktree worker of the same repo — they inherit
#    repo-root settings via the shared git common-dir, so a dead --no-worktree
#    worker's hooks would keep firing (phantom events) for workers spawned long
#    after it's gone. Keep --no-worktree settings in a private, per-id file
#    instead (never written under the shared repo root) and hand it to
#    `claude --settings` explicitly at launch; clean.sh removes it on teardown.
#    Worktree mode is unaffected: each worktree dir is unique to its worker and
#    is removed wholesale on teardown, so no cross-worker leak is possible there.
if [ "$mode" = "--no-worktree" ]; then
  mkdir -p "$STATE_DIR/settings"
  settings_file="$STATE_DIR/settings/$id.json"
else
  mkdir -p "$wdir/.claude"
  settings_file="$wdir/.claude/settings.local.json"
fi

# --allow entries are translated into valid permissions.allow tool rules (issue #78):
# Claude Code wants `ToolName` or `ToolName(specifier)` (capitalised), not bare command
# names — an entry already shaped like a tool rule (canonical `Name` or `Name(...)`)
# passes through untouched so --preset bundles and hand-written rules like
# `Bash(git diff:*)` keep working; a bare command (`git`, `gh`, `jq`) is wrapped as
# `Bash(<cmd>:*)`, which per the Claude Code docs is equivalent to `Bash(<cmd> *)`.
# The name part accepts letters/digits/underscore/hyphen (not just [A-Za-z0-9]) so a
# capitalised tool name is never wrapped just because it contains a "_" or "-" — the
# old `^[A-Z]` heuristic tolerated those too, and narrowing it would silently drop the
# permission exactly like the bug being fixed here, just for a different entry shape.
# MCP tool names are lowercase by convention (`mcp__server__tool`, optionally with
# a "(...)" specifier) so they fail the capitalised-canonical check on their own;
# they are special-cased through unwrapped rather than being wrapped as a
# (nonexistent) shell command, which silently dropped the permission (issue #84).
jq -n --arg r "$here/report.sh" --arg id "$id" --arg allow "$allow_csv" '
  {
    hooks: {
      Stop:         [{hooks:[{type:"command", command:"\($r) \($id) done"}]}],
      Notification: [{hooks:[{type:"command", command:"\($r) \($id) needs-input"}]}],
      SubagentStop: [{hooks:[{type:"command", command:"\($r) \($id) subagent-done"}]}]
    }
  }
  + (if $allow == "" then {}
     else {permissions: {allow: ($allow | split(",") | map(gsub("^\\s+|\\s+$"; ""))
       | map(select(length > 0))
       | map(if test("^[A-Z][A-Za-z0-9_-]*(\\(.*\\))?$") or test("^mcp__")
             then . else "Bash(\(.):*)" end))}}
     end)
' > "$settings_file"

# 3) initial status file
# `created` is stamped once here so downstream tools (orch status, hud.sh) can
# compute worker age; report.sh's later writes only ever touch `updated`.
# shellcheck disable=SC2016  # jq filter in single quotes; $id/$m/$t/$u are jq --arg vars, not shell
write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$(date -u +%FT%TZ)" \
  '{id:$id, status:"spawning", model:$m, task:$t, created:$u, updated:$u}'

# 4) new window + launch a full Claude Code session
# (append after the last window; bare `-t "$S"` can fail with "index 0 in use"
#  on base-index 0 sessions, so target an explicit end-of-session slot)
tmux new-window -a -t "$S:{end}" -n "$id" -c "$wdir"
tmux set-window-option -t "$S:$id" monitor-activity on
settings_flag=""
[ "$mode" = "--no-worktree" ] && settings_flag=" --settings '$settings_file'"
skip_perms_flag=""
[ -n "$skip_perms" ] && skip_perms_flag=" --dangerously-skip-permissions"
tmux send-keys -t "$S:$id" "ORCH_WORKER_ID=$id ORCH_DIR='$here' claude --model $model${settings_flag}${resume:+ $resume}${skip_perms_flag}" Enter

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

# Guard 1 (inject verification + retry, hardened by issue #51): a send can land
# before the REPL is ready and be lost entirely — or the paste can land (visible
# as an unsubmitted "[Pasted text]" chip) while the follow-up Enter fails to
# actually submit it, leaving the worker idling at the startup banner with the
# task never dispatched. Confirm the injection landed (banner scrolled away /
# pane active); if not, try a BARE Enter first, across a couple of bounded
# retries — never blindly re-paste, since the text is very likely already
# sitting in the input box and pasting it again would duplicate/corrupt it.
# Only once bare-Enter retries are exhausted does a genuinely-lost paste get one
# full re-inject as a last resort. Bounded throughout — never hangs. Still
# unconfirmed after all of that => spawn-failed, never a silently-idle
# "working" worker.
spawn_ok=0
if confirm_inject "$S:$id" 15; then
  spawn_ok=1
else
  max_retries="$(jq -r '.thresholds.spawn_inject_retries // 2' "$CONFIG")"
  retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    retry=$((retry + 1))
    log "worker $id: task injection unconfirmed; sending bare Enter (retry $retry/$max_retries)"
    tmux send-keys -t "$S:$id" Enter
    if confirm_inject "$S:$id" 15; then
      spawn_ok=1
      break
    fi
  done
  if [ "$spawn_ok" -ne 1 ]; then
    log "worker $id: bare-Enter retries exhausted; re-injecting the full task once"
    send_prompt "$S:$id" "${preamble}${task}"
    if confirm_inject "$S:$id" 15; then spawn_ok=1; fi
  fi
fi

if [ "$spawn_ok" -eq 1 ]; then
  update_worker_status "$id" '.status="working"'
  record_spend
  log "spawned $id ($model) in $wdir"
  say "spawned $id ($model)  ->  window $S:$id   dir $wdir"
else
  # Never-started worker: record it and tell the master so the spawn is not lost.
  update_worker_status "$id" '.status="spawn-failed"'
  sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
  printf '%s\n' "$sf_line" >> "$INBOX"
  printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
  log "worker $id: spawn-failed (task injection unconfirmed after retry)"
  say "spawn-failed $id ($model)  ->  window $S:$id   dir $wdir" >&2
fi
