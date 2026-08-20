#!/usr/bin/env bash
# _orch/clean.sh <id> — retire a SINGLE worker and every artifact it leaks.
# Removes, in order: the tmux window, the git worktree at ../wt/<hash>/<id>, the
# branch orch/<hash>/<id> (issue #86: <hash> namespaces the git layer per orch
# install, plus a best-effort sweep of the pre-#86 ../wt/<id>/orch/<id> layout),
# the status file workers/<id>.json, the watchdog scratch .wd-<id>, and (issue
# #43) the --no-worktree worker's private settings file settings/<id>.json.
#
# Idempotent by design: each step is guarded, so a missing session, window,
# worktree, branch, or file is a no-op rather than an error. This is what lets a
# reused id be respawned cleanly instead of silently reusing a stale worktree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$here/lib.sh"

id="${1:?usage: clean.sh <id>}"
S="$SESSION_NAME"
proj="${PROJECT_ROOT:-$(pwd)}"
wdir="$(worker_wdir "$proj" "$id")"      # spawn.sh worktree layout (issue #86)
branch="$(worker_branch "$id")"
legacy_wdir="$(legacy_worker_wdir "$proj" "$id")"     # pre-#86 layout, see below
legacy_branch="$(legacy_worker_branch "$id")"

# 1) tmux window (only if the session exists and holds a window with this name)
if tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -qx "$id"; then
  tmux kill-window -t "$S:$id" 2>/dev/null || true
  log "clean $id: killed tmux window"
fi

# 2) git worktree — force, because the worker may hold uncommitted changes. Fall
#    back to a plain rm if git cannot remove it, then prune any stale metadata so
#    the branch delete below is not blocked by a lingering worktree registration.
# Refuse to touch a worktree this install did not create — see spawn.sh (issue #86).
if [ -d "$wdir" ] && worktree_owned_by_other "$wdir"; then
  echo "clean $id: refusing to remove $wdir — owned by a different orch install ($(worktree_owner "$wdir"))" >&2
  log "clean $id: refused to remove $wdir — owned by a different orch install ($(worktree_owner "$wdir"))"
  exit 1
fi
if [ -d "$wdir" ]; then
  git -C "$proj" worktree remove --force "$wdir" >/dev/null 2>&1 || rm -rf "$wdir"
  log "clean $id: removed worktree $wdir"
fi
# Back-compat (issue #86): also sweep the pre-namespacing ../wt/<id> layout, so an
# install upgrading past this change still cleans up worktrees/branches it created
# for <id> before the upgrade. spawn.sh never creates or reuses this legacy path
# anymore — this is cleanup-only, not a fallback location for new spawns.
if [ -d "$legacy_wdir" ]; then
  git -C "$proj" worktree remove --force "$legacy_wdir" >/dev/null 2>&1 || rm -rf "$legacy_wdir"
  log "clean $id: removed legacy worktree $legacy_wdir"
fi
git -C "$proj" worktree prune >/dev/null 2>&1 || true

# 3) branch (current + legacy)
if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$proj" branch -D "$branch" >/dev/null 2>&1 || true
  log "clean $id: deleted branch $branch"
fi
if git -C "$proj" show-ref --verify --quiet "refs/heads/$legacy_branch"; then
  git -C "$proj" branch -D "$legacy_branch" >/dev/null 2>&1 || true
  log "clean $id: deleted legacy branch $legacy_branch"
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
  [ "$dropped" -gt 0 ] && echo "dropped $dropped queued spawn(s) depending on '$id'"
fi

log "clean $id: done"
echo "cleaned $id"
