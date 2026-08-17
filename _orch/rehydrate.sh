#!/usr/bin/env bash
# _orch/rehydrate.sh — build a concise "what's in flight" summary from the durable
# state under _orch/state/*, so the master can reconstruct orchestration context
# after a compaction, a restart, or whenever it's just unsure (issue #41).
#
# The master's transcript is treated as a cache: everything it actually needs to
# resume safely (live workers, queue depth, past review decisions, its own
# scratchpad) is read straight from files here, not re-derived from prior turns.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

REVIEW_LOG="$STATE_DIR/review-log.jsonl"
MASTER_NOTES="$STATE_DIR/master-notes.md"

# Print the worker table: one line per _orch/state/workers/*.json, oldest task
# text trimmed so a large backlog doesn't blow up the rehydrate message.
_rehydrate_workers() {
  shopt -s nullglob
  local f n=0
  for f in "$WORKERS_DIR"/*.json; do
    n=$((n + 1))
    jq -r '"- \(.id // "?"): status=\(.status // "?") model=\(.model // "?") task=\(.task // "" | (if length > 80 then .[0:80] + "…" else . end)) updated=\(.updated // "?")"' "$f" 2>/dev/null
  done
  [ "$n" -eq 0 ] && echo "(none)"
}

# Pending (queued-but-not-yet-spawned) items, per lib.sh's queue.jsonl.
_rehydrate_queue() {
  if [ -s "$QUEUE" ]; then
    jq -r '"- \(.id // "?"): model=\(.model // "?") task=\(.task // "" | (if length > 80 then .[0:80] + "…" else . end))"' "$QUEUE" 2>/dev/null
  else
    echo "(empty)"
  fi
}

# Last N review decisions (approve/reject/redo), most recent last.
_rehydrate_review_log() { # [n]
  local n="${1:-10}"
  if [ -s "$REVIEW_LOG" ]; then
    tail -n "$n" "$REVIEW_LOG" | jq -r '"- \(.ts // "?") \(.worker_id // "?") \(.verdict // "?"): \(.reason // "")"' 2>/dev/null
  else
    echo "(none recorded yet)"
  fi
}

_rehydrate_master_notes() {
  if [ -s "$MASTER_NOTES" ]; then
    cat "$MASTER_NOTES"
  else
    echo "(no master-notes.md yet)"
  fi
}

# Full rehydrate message, meant to be injected into (or read by) the master.
rehydrate_summary() {
  cat <<EOF
[rehydrate] Reconstructed orchestration state from _orch/state/*:

## Workers (_orch/state/workers/*.json)
$(_rehydrate_workers)

## Queued spawns (_orch/state/queue.jsonl)
$(_rehydrate_queue)

## Recent review decisions (_orch/state/review-log.jsonl, last 10)
$(_rehydrate_review_log 10)

## Master notes (_orch/state/master-notes.md)
$(_rehydrate_master_notes)

Reconcile the above against \`./orch status\` before taking any spawn/merge/review
action — these files are the source of truth, not prior transcript turns.
EOF
}

# Append one review decision. Locked with lib.sh's with_lock() the same way
# worker-status writes are, so a review decision recorded mid-heartbeat can never
# interleave with another writer's line (and it works on macOS, where flock(1)
# doesn't exist -- issue #76).
# review_log_append <worker_id> <branch> <verdict> <reason> [commit_sha]
review_log_append() {
  local worker_id="$1" branch="$2" verdict="$3" reason="$4" sha="${5:-}"
  local lock="$STATE_DIR/.review-log.lock"
  mkdir -p "$STATE_DIR"
  (
    with_lock "$lock" || exit 1
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg id "$worker_id" --arg b "$branch" \
      --arg v "$verdict" --arg r "$reason" --arg sha "$sha" \
      '{ts:$ts, worker_id:$id, branch:$b, verdict:$v, reason:$r, commit_sha:$sha}' \
      >> "$REVIEW_LOG"
  )
}

# Run the summary only when executed directly. When sourced (e.g. by hermetic
# bats tests) this exposes the helpers above without printing anything.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  rehydrate_summary
fi
