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

require_valid_session_name
S="$SESSION_NAME"

# require_session_exists() (issue #107): a bare `-t "$S"` target matches by
# UNAMBIGUOUS PREFIX, so the duplicate-window check and new-window/send-keys/
# paste-buffer below could otherwise silently create/drive a window in a
# DIFFERENT, longer-named live session instead of failing (issue #96 fixed the
# read-only existence checks; this closes the write paths). Shared helper in
# lib.sh so this guard can't drift/be forgotten per-file.
require_session_exists "$S"

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
        --arg target "$proj" --arg unrel "${ORCH_ALLOW_UNRELATED_REPO:-}" \
    '{id:$id, model:$model, task:$task, mode:$mode, resume:$resume, allow_csv:$allow, ts:$ts, reason:$reason, after:$after, target_repo:$target, allow_unrelated:$unrel}')"
  queue_push "$queue_item"
  # shellcheck disable=SC2016  # jq filter in single quotes; $id/$m/$t/$u/$a are jq --arg vars, not shell
  write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$ts" --arg a "$after_id" --arg r "$proj" \
    '{id:$id, status:"queued", model:$m, task:$t, created:$u, updated:$u, after:$a, target_repo:$r}'
  log "spawn queued for $id: waiting for dependency $after_id to reach done"
  say "spawn queued: $id ($model) waiting on '$after_id' to reach done"
  exit 0
fi

# Issue #153: refresh origin before the spawn gate, so the (up to
# ORCH_SPAWN_FETCH_TIMEOUT s) network call does not sit between the gate's
# live-worker count and this worker's status write, widening the max_workers race.
_fetch_spawn_base() { # <proj> <id>
  local proj="$1" id="$2" to="" secs="${ORCH_SPAWN_FETCH_TIMEOUT:-30}"
  # A non-numeric value would make `timeout` exit 125 and every fetch "fail";
  # 10# keeps a leading-zero value ("08") from aborting spawn as bad octal, and
  # 0 would disable timeout(1)/lowSpeedTime/ConnectTimeout (unbounded fetch).
  case "$secs" in ''|*[!0-9]*) secs=30 ;; esac
  secs=$((10#$secs)); [ "$secs" -gt 0 ] || secs=30
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    # Bounded and non-interactive: a hung/credential-prompting remote must not
    # stall spawn indefinitely.
    if command -v timeout >/dev/null 2>&1; then to="timeout $secs"
    elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout $secs"
    fi
    # GIT_TERMINAL_PROMPT only covers HTTPS; ssh can still prompt on /dev/tty
    # (and there is no `timeout` on stock macOS), so force BatchMode unless the
    # operator configured their own ssh command.
    local fetch_env=(GIT_TERMINAL_PROMPT=0)
    if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "${GIT_SSH:-}" ] \
       && ! git -C "$proj" config --get core.sshCommand >/dev/null 2>&1; then
      # ServerAlive* bounds a stalled ssh transfer after connect (ConnectTimeout
      # only covers the handshake) where no timeout(1) exists.
      fetch_env+=("GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=$secs -o ServerAliveInterval=$(( (secs + 2) / 3 )) -o ServerAliveCountMax=3")
    fi
    # http.lowSpeed* bounds a stalled HTTPS transfer even where no timeout(1)
    # exists (stock macOS); GIT_TERMINAL_PROMPT only suppresses prompts.
    # Serialised: concurrent spawns (heartbeat queue drain, back-to-back
    # `orch spawn`) would otherwise race on origin's ref locks and the loser
    # would silently branch from stale refs. Lock timeout => skip, not hang.
    # 200>&-: don't leak with_lock's flock fd to git — fetch's detached auto-gc/
    # maintenance (or an ssh ControlPersist master) would hold the lock long after.
    local rc=0
    # shellcheck disable=SC2086  # $to is an intentional word-split prefix (or empty)
    ( with_lock "$WORKERS_DIR/.spawn-fetch.lock" || exit 3
      env "${fetch_env[@]}" $to git -C "$proj" -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=$secs" \
        fetch --quiet origin </dev/null >/dev/null 2>&1 200>&- ) 2>/dev/null || rc=$?
    if [ "$rc" -eq 3 ]; then
      log "spawn $id: fetch lock busy or unavailable (another spawn fetching?); skipping git fetch origin, using last-known remote refs"
    elif [ "$rc" -ne 0 ]; then
      log "spawn $id: git fetch origin failed in $proj; using last-known remote refs"
    fi
  fi
}
[ "$mode" = "--no-worktree" ] || _fetch_spawn_base "$proj" "$id"

# Unified resource guard (issues #21 concurrency, #31 memory, #24 budget): refuse
# to launch another full Claude Code session when any cap is at/over the line, and
# persist the spawn to the pending queue instead. heartbeat.sh drains the queue as
# soon as the gate allows it again (typically once a worker reports "done").
if ! check_spawn_gate; then
  ts="$(date -u +%FT%TZ)"
  queue_item="$(jq -nc --arg id "$id" --arg model "$model" --arg task "$task" --arg mode "$mode" \
        --arg resume "$resume" --arg allow "$allow_csv" --arg ts "$ts" --arg reason "$GATE_REASON" \
        --arg target "$proj" --arg unrel "${ORCH_ALLOW_UNRELATED_REPO:-}" \
    '{id:$id, model:$model, task:$task, mode:$mode, resume:$resume, allow_csv:$allow, ts:$ts, reason:$reason, target_repo:$target, allow_unrelated:$unrel}')"
  queue_push "$queue_item"
  # shellcheck disable=SC2016  # jq filter in single quotes; $id/$m/$t/$u are jq --arg vars, not shell
  write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$ts" --arg r "$proj" \
    '{id:$id, status:"queued", model:$m, task:$t, created:$u, updated:$u, target_repo:$r}'
  log "spawn refused for $id: $GATE_REASON; queued"
  say "spawn queued: $id ($model) refused — $GATE_REASON"
  exit 0
fi

# Issue #153: pick the commit a new worker worktree branches from — the remote
# base (origin/${ORCH_BASE_BRANCH:-main}), not the target checkout's HEAD.
# Sets globals base_ref/base_sha (base_ref stays empty if nothing resolves).
# Reads the remote-tracking refs _fetch_spawn_base refreshed before the gate.
_resolve_spawn_base() { # <proj> <id>
  local proj="$1" id="$2" want="${ORCH_BASE_BRANCH:-main}" cand local_sha
  base_ref=""; base_sha=""
  # An explicitly requested local $want beats the remote's default branch:
  # origin/HEAD may be a different branch entirely (e.g. main vs develop).
  for cand in "origin/$want" "$want" origin/HEAD HEAD; do
    if git -C "$proj" rev-parse -q --verify "$cand^{commit}" >/dev/null 2>&1; then
      base_ref="$cand"; break
    fi
  done
  [ -n "$base_ref" ] || return 0
  # origin/HEAD is a symref that `remote set-head` can repoint; record the
  # concrete branch it names so collect diffs against the same branch later.
  if [ "$base_ref" = origin/HEAD ]; then
    base_ref="$(git -C "$proj" rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo origin/HEAD)"
  fi
  base_sha="$(git -C "$proj" rev-parse "$base_ref^{commit}" 2>/dev/null)"
  # HEAD moves with the target checkout; pin the HEAD fallback to its sha.
  [ "$base_ref" != HEAD ] || base_ref="$base_sha"
  if [ "$base_ref" != "origin/$want" ]; then
    log "spawn $id: origin/$want not found in $proj; basing worker on $base_ref"
  elif local_sha="$(git -C "$proj" rev-parse -q --verify "refs/heads/$want" 2>/dev/null)" \
       && [ "$local_sha" != "$base_sha" ]; then
    log "spawn $id: local $want ($local_sha) differs from $base_ref ($base_sha); basing worker on $base_ref"
  fi
}

# 1) working directory: isolated worktree (default) or the project root
base_ref=""; base_sha=""
if [ "$mode" = "--no-worktree" ]; then
  wdir="$proj"
else
  # Namespaced per install (issue #86): $proj/../wt/<hash-of-ORCH_ROOT>/<id> on
  # branch orch/<hash>/<id>, so two orch installs targeting the same repo never
  # want the same path/branch for the same worker id.
  wdir="$(worker_wdir "$proj" "$id")"
  branch="$(worker_branch "$id")"
  _resolve_spawn_base "$proj" "$id"
  # Guard (issue #37): a pre-existing path at $wdir must not be silently reused
  # just because `worktree add` failed on it. Decide deterministically instead:
  # reuse only if it is verifiably a clean worktree of THIS repo on $branch AND
  # owned by THIS install (issue #86); otherwise fail loudly rather than run the
  # worker against an unknown or foreign-owned tree.
  if [ -e "$wdir" ]; then
    if worktree_owned_by_other "$wdir"; then
      owner="$(worktree_owner "$wdir")"
      log "spawn refused for $id: $wdir is owned by a different orch install ($owner)"
      # shellcheck disable=SC2016  # $r is a jq --arg var, not shell
      update_worker_status "$id" --arg r "$proj" '.status="spawn-failed" | .target_repo=$r'
      sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
      printf '%s\n' "$sf_line" >> "$INBOX"
      printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
      say "spawn-failed $id: $wdir is owned by a different orch install ($owner), not this one ($ORCH_ROOT)." >&2
      say "Use a different id, or clean it up from that install." >&2
      exit 1
    elif worktree_matches_expected "$proj" "$wdir" "$branch"; then
      log "worktree add: $wdir already a clean worktree of $proj on $branch; reusing"
      stamp_worktree_owner "$wdir" || true
      # Still record base/base_sha (#153) so collect does not fall back to a
      # stale local main for a reused worktree; base_sha is the fork point.
      if [ -n "$base_ref" ]; then
        base_sha="$(git -C "$proj" merge-base "$base_ref" "refs/heads/$branch" 2>/dev/null || true)"
      fi
    else
      log "spawn refused for $id: $wdir exists and is not a clean worktree of $proj on $branch"
      # shellcheck disable=SC2016  # $r is a jq --arg var, not shell
      update_worker_status "$id" --arg r "$proj" '.status="spawn-failed" | .target_repo=$r'
      sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
      printf '%s\n' "$sf_line" >> "$INBOX"
      printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
      say "spawn-failed $id: $wdir exists and is not a valid worktree for this repo/branch." >&2
      say "Run 'orch clean $id' to remove it, or use a different id." >&2
      exit 1
    fi
  # Branch from the resolved base_sha, not the base_ref name: a concurrent spawn's
  # fetch can move origin/<base> after resolution, and the recorded base_sha must
  # be this worker's actual fork point.
  elif ! git -C "$proj" worktree add --no-track -B "$branch" "$wdir" ${base_sha:+"$base_sha"} >/dev/null 2>&1; then
    log "spawn refused for $id: git worktree add failed for $wdir"
    # shellcheck disable=SC2016  # $r is a jq --arg var, not shell
    update_worker_status "$id" --arg r "$proj" '.status="spawn-failed" | .target_repo=$r'
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
#
# issue #163: the Notification hook is scoped to the types that mean the worker is
# blocked on a human. Unmatched, idle_prompt (60 s after every Stop) and the
# informational types ran it too, reporting a false needs-input and overwriting a
# finished worker's `done`. AskUserQuestion and other untyped blocking dialogs
# (plan approval, sandbox network request) default to permission_prompt;
# agent_needs_input is a blocking dialog too (auto-mode billing notice, a background
# agent parked on input) and worker_permission_prompt is an agent-team teammate
# waiting on this worker's approval. Values are exact-match (code.claude.com hooks
# reference, Notification matchers) -- a typo silently drops that type.
# worker-settings.template.json mirrors this list (checked by tests/spawn.bats); README.md quotes it.
notif_matcher="permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|worker_permission_prompt"
#
# issue #144: awaySummaryEnabled is the documented settings key that suppresses
# the session recap row, belt-and-braces alongside ORCH_GHOST_ENV (lib.sh).
jq -n --arg r "$here/report.sh" --arg id "$id" --arg allow "$allow_csv" --arg nm "$notif_matcher" '
  {
    awaySummaryEnabled: false,
    hooks: {
      Stop:         [{hooks:[{type:"command", command:"\($r) \($id) done --hook"}]}],
      Notification: [{matcher:$nm, hooks:[{type:"command", command:"\($r) \($id) needs-input"}]}],
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
write_worker_status "$id" --arg id "$id" --arg m "$model" --arg t "$task" --arg u "$(date -u +%FT%TZ)" --arg r "$proj" \
  --arg base "${base_ref:-}" --arg base_sha "${base_sha:-}" \
  '{id:$id, status:"spawning", model:$m, task:$t, created:$u, updated:$u, target_repo:$r}
   + (if $base_sha == "" then {} else {base:$base, base_sha:$base_sha} end)'

# 4) new window + launch a full Claude Code session
# (append after the last window; bare `-t "$S"` can fail with "index 0 in use"
#  on base-index 0 sessions, so target an explicit end-of-session slot)
tmux new-window -a -t "$S:{end}" -n "$id" -c "$wdir"
tmux set-window-option -t "$S:$id" monitor-activity on
settings_flag=""
[ "$mode" = "--no-worktree" ] && settings_flag=" --settings '$settings_file'"
skip_perms_flag=""
[ -n "$skip_perms" ] && skip_perms_flag=" --dangerously-skip-permissions"
# issue #140: ORCH_GHOST_ENV (lib.sh) is the env-var route -- not the disproved
# prompt-suggestions CLI flag -- that suppresses the prompt-suggestion ghost
# row; belt-and-braces alongside pane_has_draft().
tmux send-keys -t "$S:$id" "ORCH_WORKER_ID=$id ORCH_DIR='$here' ${ORCH_GHOST_ENV}claude --model $model${settings_flag}${resume:+ $resume}${skip_perms_flag}" Enter

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

# Guard 3 (dialog safety, issues #132/#133): never send a paste-with-trailing-Enter
# (send_prompt) or a bare Enter into a pane showing a dialog. Both the permission
# and folder-trust dialogs render a page of choices with a highlighted default, and
# Enter selects it -- it does not "submit the input box". This matters even here,
# BEFORE the first injection attempt: wait_ready()'s readiness regex includes the
# bare "❯" glyph, which the trust dialog's highlighted-choice arrow ("❯ No, exit")
# also matches, so wait_ready can report "ready" while the dialog -- not the REPL
# prompt -- is actually on screen. That is #133's production repro: the trust
# dialog's Enter is destructive (exits the session), and --dangerously-skip-permissions
# does not suppress it. If a dialog is already up, skip this send entirely; the
# retry loop below sends the task itself (a paste, not a bare Enter into an
# empty input box) only once the dialog has cleared, and never presses Enter
# into it. task_sent records whether the task has gone out at all: until it
# has, no pane evidence can confirm it -- a ready prompt after the dialog
# clears would otherwise "confirm" a task that was never sent.
# The pane being back at a shell is held back the same way: claude exited during
# startup (bad --resume id, auth failure, ...) and a shell prompt glyph such as
# "❯" satisfied wait_ready -- a paste+Enter there runs the task text as shell
# commands. send_task() below re-checks before any later send.
# A claude started through a shell wrapper that doesn't exec also leaves a shell
# as the pane's foreground command, so a shell only counts once no claude/node
# process is running anywhere under the pane.
pane_runs_shell() {
  local pid
  case "$(tmux display-message -p -t "$S:$id" '#{pane_current_command}' 2>/dev/null)" in
    sh|bash|zsh|dash|ksh|mksh|fish|tcsh|csh|nu|xonsh|elvish|-sh|-bash|-zsh|-dash|-ksh|-fish|-tcsh|-csh) ;;
    *) return 1 ;;
  esac
  pid="$(tmux display-message -p -t "$S:$id" '#{pane_pid}' 2>/dev/null)"
  [ -n "$pid" ] || return 0
  # shellcheck disable=SC2016  # awk program, not shell
  ps -A -o pid= -o ppid= -o comm= 2>/dev/null | awk -v root="$pid" '
    { par[$1] = $2; c = $3; sub(/.*\//, "", c); name[$1] = c }
    END {
      for (x in par) {
        if (name[x] != "claude" && name[x] != "node") continue
        y = x
        while ((y in par) && y != root && y > 1) y = par[y]
        if (y == root) exit 1
      }
      exit 0
    }'
}
# The shell is still there after a bounded grace window (0 = it persists). Right
# after the launch line the pane is briefly still the shell -- and a "❯" prompt
# theme satisfies wait_ready -- so one instantaneous check would misread a
# claude that is still starting as one that exited.
shell_persists() {
  local i=0
  while pane_runs_shell; do
    [ "$i" -ge 10 ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
task_sent=0
if pane_has_dialog "$S:$id"; then
  log "worker $id: dialog on screen before first injection attempt; not sending"
elif pane_runs_shell; then
  log "worker $id: claude is not running in the pane (shell prompt) before first injection attempt; not sending"
else
  send_prompt "$S:$id" "${preamble}${task}"
  task_sent=1
fi

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
# A worker hook (Stop/Notification/SubagentStop) that already moved the status off
# "spawning" proves the task was submitted, even if the pane checks never confirmed
# it -- checked before every retry so a task that already ran is never re-pasted,
# and never reported spawn-failed (issue #163 review).
# One list, shared by hook_reported() and the locked spawn-failed write below.
hook_statuses='["done","waiting-bg","needs-input","subagent-done"]'
# shellcheck disable=SC2016  # $c/$hs are jq variables, not shell
hook_status_filter='(.status // "") as $c | $hs | map(. == $c) | any'
hook_reported() {
  # A hook status only proves submission once the task has actually gone out:
  # while a dialog is still holding the first send back, a Notification hook can
  # fire for the dialog itself (issues #132/#133).
  [ "$task_sent" -eq 1 ] || return 1
  if jq -e --argjson hs "$hook_statuses" "$hook_status_filter" "$WORKERS_DIR/$id.json" >/dev/null 2>&1; then
    log "worker $id: injection unconfirmed by pane, but a hook already reported; treating as spawned"
    return 0
  fi
  return 1
}
# Send the task and record it as sent. On a FIRST send that a dialog held back,
# first clear any hook status written in the meantime (e.g. a Notification for
# the dialog itself): it predates the task, so leaving it would let
# hook_reported() count a lost paste as submitted (issues #132/#133).
# A held-back first send also waits for the REPL prompt: the dialog vanishing
# only means it unmounted, and Claude Code may still be initialising -- a paste
# sent into that gap is the #51 lost-send shape.
# Returns 1 WITHOUT sending when the pane is back at a shell: "dialog gone" also
# covers claude having exited (e.g. "No, exit" picked on the trust dialog), and
# a paste+Enter there would run the task text as shell commands. The shell is
# checked before the REPL wait too, so an exited claude doesn't burn 15s first.
# Returns 2 WITHOUT sending when a dialog is (back) on screen after that wait:
# wait_ready's bare-"❯" match is satisfied by a dialog's highlighted choice, so
# a dialog rendering during the wait would otherwise take the paste's Enter.
send_task() {
  if shell_persists; then
    log "worker $id: claude is no longer running in the pane (shell prompt); not sending the task"
    return 1
  fi
  if [ "$task_sent" -ne 1 ]; then
    wait_ready "$S:$id" 15 || log "worker $id: REPL not ready 15s after the dialog cleared; sending anyway"
    # claude can exit during that wait too.
    if pane_runs_shell; then
      log "worker $id: claude is no longer running in the pane (shell prompt); not sending the task"
      return 1
    fi
  fi
  if pane_has_dialog "$S:$id"; then
    log "worker $id: dialog on screen again; not sending the task"
    return 2
  fi
  if [ "$task_sent" -ne 1 ]; then
    update_worker_status "$id" --argjson hs "$hook_statuses" \
      ".status = (if ($hook_status_filter) then \"spawning\" else .status end)"
  fi
  send_prompt "$S:$id" "${preamble}${task}"
  task_sent=1
}
# confirm_inject, but only once the task was actually sent; before that, just
# give an on-screen dialog the same bounded window to clear, and report
# "not confirmed".
confirm_sent() {
  if [ "$task_sent" -ne 1 ]; then
    local i=0
    while [ "$i" -lt 15 ] && pane_has_dialog "$S:$id"; do sleep 1; i=$((i+1)); done
    return 1
  fi
  confirm_inject "$S:$id" 15
}
spawn_ok=0
if confirm_sent || hook_reported; then
  spawn_ok=1
else
  max_retries="$(jq -r '.thresholds.spawn_inject_retries // 2' "$CONFIG")"
  retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    retry=$((retry + 1))
    if pane_has_dialog "$S:$id"; then
      # Guard 3 continued: a dialog appeared (or is still there) -- refuse the
      # bare Enter. Once the task is sent, a permission dialog counts as
      # confirmed evidence in inject_confirmed(); before then (task_sent=0)
      # confirm_sent() never consults it. Either way sending Enter here risks
      # picking a destructive default. Just re-poll.
      log "worker $id: dialog on screen (retry $retry/$max_retries); refusing bare Enter"
    elif [ "$task_sent" -ne 1 ]; then
      # The dialog that blocked the first injection has cleared: nothing is in
      # the input box for a bare Enter to submit, so send the task itself.
      log "worker $id: dialog cleared; sending the task (retry $retry/$max_retries)"
      send_rc=0
      send_task || send_rc=$?
      [ "$send_rc" -eq 1 ] && break
      # This rung is the FIRST send, not a bare-Enter retry: hand its budget
      # back so the #51 bare-Enter retries stay available for this paste even
      # when the dialog outlasted earlier rungs. Bounded: task_sent flips once.
      # A send held back by a returning dialog (rc 2) keeps the rung spent.
      [ "$send_rc" -eq 0 ] && retry=$((retry - 1))
    else
      log "worker $id: task injection unconfirmed; sending bare Enter (retry $retry/$max_retries)"
      tmux send-keys -t "$S:$id" Enter
    fi
    if confirm_sent || hook_reported; then
      spawn_ok=1
      break
    fi
  done
  if [ "$spawn_ok" -ne 1 ]; then
    # Last resort only when the text is demonstrably NOT still sitting in the
    # input box and NOT hidden behind a dialog (issues #132/#133). If the pane
    # still shows an un-submitted "[Pasted text]" chip, re-pasting would append
    # a SECOND copy of the task next to the first and submit both -- exactly
    # the duplication this ladder exists to avoid. If a dialog is on screen,
    # pasting into it (and its trailing Enter) risks the same destructive
    # selection Guard 3 exists to prevent. Better a clean spawn-failed the
    # master can retry than a silently corrupted or destructively-exited spawn.
    if pane_has_pending_paste "$S:$id"; then
      log "worker $id: task text still sits unsent in the input box; not re-pasting (would duplicate it)"
    elif pane_has_dialog "$S:$id"; then
      log "worker $id: dialog on screen; not re-pasting (would be consumed as a dialog choice)"
      # A permission dialog that rendered only after the last poll is still
      # positive evidence the (already sent) task landed (issue #133).
      if [ "$task_sent" -eq 1 ] && pane_has_permission_dialog "$S:$id"; then spawn_ok=1; fi
    else
      if [ "$task_sent" -eq 1 ]; then
        log "worker $id: bare-Enter retries exhausted; re-injecting the full task once"
      else
        # The dialog only cleared during the final rung's wait: this is the
        # FIRST send, not a re-inject.
        log "worker $id: dialog cleared after the last retry; sending the task once"
      fi
      first_send=$((1 - task_sent))
      if ! send_task; then
        # claude exited or a dialog came back; nothing was sent -> spawn-failed
        # below -- unless the dialog that came back is a permission dialog for
        # the already-sent task, which is positive evidence it landed (#133).
        if [ "$task_sent" -eq 1 ] && pane_has_permission_dialog "$S:$id"; then spawn_ok=1; fi
      elif confirm_sent || hook_reported; then
        spawn_ok=1
      elif [ "$first_send" -eq 1 ] && ! pane_has_dialog "$S:$id"; then
        # A first send gets the same one bare-Enter follow-up the #51 ladder
        # gives every other paste: its trailing Enter may have been lost.
        log "worker $id: first send unconfirmed; sending one bare Enter"
        tmux send-keys -t "$S:$id" Enter
        if confirm_sent || hook_reported; then spawn_ok=1; fi
      fi
    fi
  fi
fi

if [ "$spawn_ok" -ne 1 ]; then
  # Mark spawn-failed in the same locked read-modify-write that re-checks for a hook
  # status: a Stop/Notification landing after the last hook_reported() check must
  # not be clobbered into spawn-failed (and reaped) while the worker is running.
  # A task that never went out is spawn-failed whatever a hook reported.
  update_worker_status "$id" --argjson hs "$hook_statuses" --argjson sent "$task_sent" \
    ".status = (if \$sent == 1 and ($hook_status_filter) then .status else \"spawn-failed\" end)"
  hook_reported && spawn_ok=1
fi

if [ "$spawn_ok" -eq 1 ]; then
  # Only promote "spawning": a fast first Stop/Notification (done, waiting-bg,
  # needs-input) that already landed under the lock must not be clobbered.
  update_worker_status "$id" '.status = (if (.status // "spawning") == "spawning" then "working" else .status end)'
  record_spend
  log "spawned $id ($model) in $wdir"
  say "spawned $id ($model)  ->  window $S:$id   dir $wdir"
else
  # Never-started worker (status already set to spawn-failed above): tell the
  # master so the spawn is not lost.
  sf_line="$(printf '{"id":"%s","event":"spawn-failed","ts":"%s"}' "$id" "$(date -u +%FT%TZ)")"
  printf '%s\n' "$sf_line" >> "$INBOX"
  printf '%s\n' "$sf_line" >> "$STATE_DIR/events.jsonl"
  log "worker $id: spawn-failed (task injection unconfirmed after retry)"
  say "spawn-failed $id ($model)  ->  window $S:$id   dir $wdir" >&2
fi
