#!/usr/bin/env bash
# _orch/merge.sh <id> [--auto] [--base <branch>]
# Opt-in CI-gated auto-merge (issue #36): for a finished worker branch orch/<id>,
# push it, open (or reuse) a PR against main, and — ONLY when explicitly opted in
# via --auto or merge.auto in config.json — wait for required CI checks and
# squash-merge (+ delete branch) once every required check is SUCCESS.
#
# Guardrails (issue #36, non-negotiable):
#   - Opt-in only: without --auto (and merge.auto=false in config), this command
#     only pushes + opens/reuses the PR and reports check status. It never merges.
#   - Never merges a CONFLICTING/DIRTY PR — reports and stops, does not force.
#   - Never bypasses branch protection / required checks (plain `gh pr merge`,
#     no --admin).
#   - Every merge/merge-blocked decision is appended to the durable event log
#     (events.jsonl, issue #19) and the inbox, so the master hears about it the
#     same way a heartbeat/watchdog event does.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$here/lib.sh"

id=""
auto=0
base="${ORCH_BASE_BRANCH:-main}"
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) auto=1; shift ;;
    --base) base="${2:?--base needs a branch name}"; shift 2 ;;
    *)
      if [ -z "$id" ]; then id="$1"; shift; else say "merge: unexpected arg: $1" >&2; exit 1; fi
      ;;
  esac
done
[ -n "$id" ] || { say "usage: merge.sh <id> [--auto] [--base <branch>]" >&2; exit 1; }

proj="${PROJECT_ROOT:-$(pwd)}"
branch="$(worker_branch "$id")"
# Back-compat (issue #86): fall back to the pre-#86 orch/<id> branch for a
# worker spawned before this install upgraded to the namespaced layout, so an
# in-flight worker's PR can still be pushed/merged across the upgrade.
if ! git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
  legacy_branch="$(legacy_worker_branch "$id")"
  if git -C "$proj" show-ref --verify --quiet "refs/heads/$legacy_branch"; then
    branch="$legacy_branch"
  fi
fi

# merge.auto in config.json lets an operator opt the whole toolkit into
# auto-merge without repeating --auto on every invocation; the CLI flag always
# wins if given. Either way this is an explicit, readable opt-in — never the
# default (issue #36 guardrail).
cfg_auto="$(jq -r '.merge.auto // false' "$CONFIG" 2>/dev/null || echo false)"
if [ "$auto" -eq 0 ] && [ "$cfg_auto" = "true" ]; then auto=1; fi

poll_interval="$(jq -r '.merge.poll_interval_seconds // 15' "$CONFIG" 2>/dev/null || echo 15)"
timeout_seconds="$(jq -r '.merge.timeout_seconds // 1800' "$CONFIG" 2>/dev/null || echo 1800)"
mapfile -t required_checks < <(jq -r '.merge.required_checks // [] | .[]' "$CONFIG" 2>/dev/null || true)

_emit_event() { # <event> <reason>
  local ev="$1" reason="${2:-}" ts; ts="$(date -u +%FT%TZ)"
  local line
  line="$(jq -n --arg id "$id" --arg event "$ev" --arg ts "$ts" --arg reason "$reason" \
    '{id:$id, event:$event, ts:$ts} + (if ($reason|length)>0 then {reason:$reason} else {} end)')"
  printf '%s\n' "$line" >> "$INBOX"
  printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
}

_block() { # <reason>
  local reason="$1"
  # shellcheck disable=SC2016  # jq filter in single quotes; $s/$t are jq --arg vars, not shell
  update_worker_status "$id" --arg s "blocked" --arg t "$(date -u +%FT%TZ)" \
    '.status=$s | .updated=$t' || true
  _emit_event "merge-blocked" "$reason"
  log "merge $id: blocked — $reason"
  say "merge $id: blocked — $reason" >&2
}

if ! git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
  say "merge: branch $branch does not exist" >&2
  exit 1
fi

log "merge $id: pushing $branch"
if ! git -C "$proj" push -u origin "$branch" 2>&1 | tee -a "$LOG"; then
  say "merge: push failed for $branch" >&2
  exit 1
fi

pr_url="$(cd "$proj" && gh pr view "$branch" --json url -q .url 2>/dev/null || true)"
if [ -z "$pr_url" ]; then
  log "merge $id: opening PR for $branch -> $base"
  if ! pr_url="$(cd "$proj" && gh pr create --base "$base" --head "$branch" \
      --title "$id" --body "Automated PR for worker '$id' (orch merge)." 2>&1)"; then
    say "merge: failed to open PR for $branch: $pr_url" >&2
    exit 1
  fi
else
  log "merge $id: reusing existing PR $pr_url"
fi

pr_json="$(cd "$proj" && gh pr view "$branch" --json number,url,state,mergeable,mergeStateStatus 2>&1)" || {
  say "merge: failed to inspect PR for $branch: $pr_json" >&2
  exit 1
}
mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<< "$pr_json")"
merge_state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<< "$pr_json")"

echo "$pr_json"

if [ "$auto" -eq 0 ]; then
  log "merge $id: opt-in not set (no --auto, merge.auto=$cfg_auto) — PR ready, not merging"
  exit 0
fi

# Guardrail: never merge a conflicting/dirty PR — report, don't force.
if [ "$mergeable" = "CONFLICTING" ] || [ "$merge_state" = "DIRTY" ]; then
  _block "PR is $merge_state/$mergeable — resolve conflicts before merging"
  exit 1
fi

# --- wait for required checks -------------------------------------------------
elapsed=0
outcome="timeout"
while [ "$elapsed" -le "$timeout_seconds" ]; do
  checks_json="$(cd "$proj" && gh pr checks "$branch" --json name,bucket,state 2>&1)" || checks_json="[]"
  if ! jq -e . >/dev/null 2>&1 <<< "$checks_json"; then
    checks_json="[]"
  fi

  if [ "${#required_checks[@]}" -eq 0 ]; then
    relevant_json="$checks_json"
  else
    relevant_json="$(jq -c --argjson names "$(printf '%s\n' "${required_checks[@]}" | jq -R . | jq -s .)" \
      '[.[] | select(.name as $n | $names | index($n))]' <<< "$checks_json")"
  fi

  total="$(jq 'length' <<< "$relevant_json")"
  failed="$(jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' <<< "$relevant_json")"
  passed="$(jq '[.[] | select(.bucket == "pass")] | length' <<< "$relevant_json")"

  if [ "$failed" -gt 0 ]; then
    outcome="failed"
    break
  fi
  if [ "$total" -gt 0 ] && [ "$passed" -eq "$total" ]; then
    if [ "${#required_checks[@]}" -eq 0 ] || [ "$passed" -ge "${#required_checks[@]}" ]; then
      outcome="success"
      break
    fi
  fi

  sleep "$poll_interval"
  elapsed=$((elapsed + poll_interval))
done

case "$outcome" in
  success)
    log "merge $id: all required checks green — merging"
    if merge_out="$(cd "$proj" && gh pr merge "$branch" --squash --delete-branch 2>&1)"; then
      # shellcheck disable=SC2016  # jq filter in single quotes; $s/$t are jq --arg vars, not shell
      update_worker_status "$id" --arg s "merged" --arg t "$(date -u +%FT%TZ)" \
        '.status=$s | .updated=$t' || true
      _emit_event "merged" ""
      log "merge $id: merged and branch deleted"
      say "merge $id: merged"
      exit 0
    else
      _block "gh pr merge failed: $merge_out"
      exit 1
    fi
    ;;
  failed)
    _block "one or more required checks failed"
    exit 1
    ;;
  timeout)
    _block "timed out after ${timeout_seconds}s waiting for required checks"
    exit 1
    ;;
esac
