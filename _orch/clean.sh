#!/usr/bin/env bash
# _orch/clean.sh <id> [--sweep-legacy] — retire a SINGLE worker and every
# artifact it leaks. Removes, in order: the tmux window, the git worktree at
# ../wt/<hash>/<id>, the branch orch/<hash>/<id> (issue #86: <hash> namespaces
# the git layer per orch install), the status file workers/<id>.json, the
# watchdog scratch .wd-<id>, and (issue #43) the --no-worktree worker's
# private settings file settings/<id>.json.
#
# --sweep-legacy (issue #86 migration): ALSO remove the pre-#86, un-namespaced
# ../wt/<id> worktree and orch/<id> branch for the same id, if present. Off by
# default and opt-in only: an un-namespaced worktree carries no ownership
# marker (the feature predates it), so unlike the namespaced path above this
# install cannot tell whether it or a DIFFERENT, not-yet-upgraded orch install
# targeting the same repo created it. Auto-sweeping it would reintroduce the
# exact cross-install destruction #86 fixes, just against legacy artifacts, in
# a mixed-version rollout where one install has upgraded past this change and
# another (still on old spawn.sh) is actively using the legacy layout for a
# live worker with the same id. Pass --sweep-legacy only once you know every
# install touching this repo has upgraded, or you've confirmed by hand that
# the legacy worktree is actually stale.
#
# Idempotent by design: each step is guarded, so a missing session, window,
# worktree, branch, or file is a no-op rather than an error. This is what lets a
# reused id be respawned cleanly instead of silently reusing a stale worktree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$here/lib.sh"

id=""
sweep_legacy=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sweep-legacy) sweep_legacy=1; shift ;;
    *)
      if [ -z "$id" ]; then id="$1"; shift; else say "clean: unexpected arg: $1" >&2; exit 1; fi
      ;;
  esac
done
[ -n "$id" ] || { say "usage: clean.sh <id> [--sweep-legacy]" >&2; exit 1; }

require_valid_session_name
S="$SESSION_NAME"
proj="${PROJECT_ROOT:-$(pwd)}"
wdir="$(worker_wdir "$proj" "$id")"      # spawn.sh worktree layout (issue #86)
branch="$(worker_branch "$id")"
legacy_wdir="$(legacy_worker_wdir "$proj" "$id")"     # pre-#86 layout, see above
legacy_branch="$(legacy_worker_branch "$id")"

# 0) Refuse up front, before touching ANYTHING, if the worktree belongs to a
# different orch install (issue #86) — checked first so a refusal is a true
# no-op (all-or-nothing) rather than leaving the tmux window already killed
# while the worktree/branch/status file survive in a half-torn-down state.
if [ -d "$wdir" ] && worktree_owned_by_other "$wdir"; then
  say "clean $id: refusing to remove $wdir — owned by a different orch install ($(worktree_owner "$wdir"))" >&2
  log "clean $id: refused to remove $wdir — owned by a different orch install ($(worktree_owner "$wdir"))"
  exit 1
fi

# 1) tmux window (only if the session exists and holds a window with this name)
if tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  tmux kill-window -t "$S:$id" 2>/dev/null || true
  log "clean $id: killed tmux window"
fi

# 2) git worktree — force, because the worker may hold uncommitted changes. Fall
#    back to a plain rm if git cannot remove it, then prune any stale metadata so
#    the branch delete below is not blocked by a lingering worktree registration.
if [ -d "$wdir" ]; then
  git -C "$proj" worktree remove --force "$wdir" >/dev/null 2>&1 || rm -rf "$wdir"
  log "clean $id: removed worktree $wdir"
  # This install's own namespace dir ($proj/../wt/<hash>) is otherwise never
  # cleaned up once the last worker under it is retired.
  rmdir "$(dirname "$wdir")" 2>/dev/null || true
fi
# Back-compat (issue #86): the pre-namespacing ../wt/<id> layout is swept ONLY
# on explicit --sweep-legacy (see the header comment above for why this is not
# automatic). Without the flag, just tell the operator it's there.
if [ -d "$legacy_wdir" ]; then
  if [ "$sweep_legacy" -eq 1 ]; then
    git -C "$proj" worktree remove --force "$legacy_wdir" >/dev/null 2>&1 || rm -rf "$legacy_wdir"
    log "clean $id: removed legacy worktree $legacy_wdir (--sweep-legacy)"
  else
    say "clean $id: leaving pre-#86 legacy worktree $legacy_wdir in place (pass --sweep-legacy to remove it, once you're sure no other un-upgraded orch install owns it)" >&2
    log "clean $id: found legacy worktree $legacy_wdir, not removed (no --sweep-legacy)"
  fi
fi
git -C "$proj" worktree prune >/dev/null 2>&1 || true

# 3) branch (current always; legacy only with --sweep-legacy, see above)
if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$proj" branch -D "$branch" >/dev/null 2>&1 || true
  log "clean $id: deleted branch $branch"
fi
if [ "$sweep_legacy" -eq 1 ] && git -C "$proj" show-ref --verify --quiet "refs/heads/$legacy_branch"; then
  git -C "$proj" branch -D "$legacy_branch" >/dev/null 2>&1 || true
  log "clean $id: deleted legacy branch $legacy_branch (--sweep-legacy)"
fi

# 4) status file + 5) watchdog scratch + 6) --no-worktree settings file (issue #43:
#    spawn.sh writes --no-worktree hooks to a private per-id file instead of the
#    shared repo root; it must not outlive the worker either)
rm -f "$WORKERS_DIR/$id.json"
rm -f "$STATE_DIR/.wd-$id"
rm -f "$STATE_DIR/settings/$id.json"

# 7) this worker's status-file lock (issue #79): _worker_lock_file() from lib.sh,
#    plus any mkdir-fallback ".lock.d" directory the portable lock shim (#76)
#    leaves behind on platforms without flock(1). Orphaned locks are harmless in
#    isolation, but they're cruft in a state dir whose whole point is to reflect
#    what actually exists.
lock_file="$(_worker_lock_file "$id")"
if [ -e "$lock_file" ] || [ -e "$lock_file.d" ]; then
  rm -f "$lock_file"
  rm -rf "$lock_file.d"
  log "clean $id: removed lock file/dir"
fi

# 8) queue entries that can never fire (issue #79): a queued spawn held with
#    `--after <id>` becomes permanently unsatisfiable once <id> is cleaned — its
#    "done" status will never happen — so it would otherwise linger in the queue
#    forever, one freed slot away from launching and redoing already-finished
#    work. Drop only entries depending on THIS id; an entry depending on some
#    other worker must survive untouched. Log what was dropped (and why) rather
#    than silently discarding queued work.
if [ -s "$QUEUE" ]; then
  tmp="$QUEUE.tmp.$$"
  dropped=0
  : > "$tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    after="$(jq -r '.after // empty' <<<"$line")"
    if [ "$after" = "$id" ]; then
      dropped=$((dropped + 1))
      qid="$(jq -r '.id // "?"' <<<"$line")"
      log "clean $id: dropped queued spawn '$qid' — its --after '$id' dependency can never be satisfied now"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
  [ "$dropped" -gt 0 ] && say "dropped $dropped queued spawn(s) depending on '$id'"
fi

log "clean $id: done"
say "cleaned $id"
