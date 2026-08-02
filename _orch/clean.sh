#!/usr/bin/env bash
# _orch/clean.sh <id> — retire a SINGLE worker and every artifact it leaks.
# Removes, in order: the tmux window, the git worktree at ../wt/<id>, the branch
# orch/<id>, the status file workers/<id>.json, the watchdog scratch .wd-<id>, and
# (issue #43) the --no-worktree worker's private settings file settings/<id>.json.
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
wdir="$proj/../wt/$id"   # spawn.sh worktree layout: $PROJECT_ROOT/../wt/<id>

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
fi
git -C "$proj" worktree prune >/dev/null 2>&1 || true

# 3) branch orch/<id>
if git -C "$proj" show-ref --verify --quiet "refs/heads/orch/$id"; then
  git -C "$proj" branch -D "orch/$id" >/dev/null 2>&1 || true
  log "clean $id: deleted branch orch/$id"
fi

# 4) status file + 5) watchdog scratch + 6) --no-worktree settings file (issue #43:
#    spawn.sh writes --no-worktree hooks to a private per-id file instead of the
#    shared repo root; it must not outlive the worker either)
rm -f "$WORKERS_DIR/$id.json"
rm -f "$STATE_DIR/.wd-$id"
rm -f "$STATE_DIR/settings/$id.json"

log "clean $id: done"
echo "cleaned $id"
