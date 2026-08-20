#!/usr/bin/env bash
# _orch/collect.sh <id> [--base <branch>]
# The uniform deliverable surface (issue #23): emits one JSON object combining
# a worker's branch diff (git diff <base>...orch/<id>) and its status file, so
# the orchestrator has a single command instead of scraping panes/diffs ad hoc.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # runtime-resolved path; not followed by shellcheck
source "$here/lib.sh"

id=""
base="${ORCH_BASE_BRANCH:-main}"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a branch name}"; shift 2 ;;
    *)
      if [ -z "$id" ]; then id="$1"; shift; else echo "collect: unexpected arg: $1" >&2; exit 1; fi
      ;;
  esac
done
[ -n "$id" ] || { echo "usage: collect.sh <id> [--base <branch>]" >&2; exit 1; }

proj="${PROJECT_ROOT:-$(pwd)}"
branch="$(worker_branch "$id")"
status_file="$WORKERS_DIR/$id.json"

if [ -f "$status_file" ] && jq -e . "$status_file" >/dev/null 2>&1; then
  status_json="$(cat "$status_file")"
else
  status_json="null"
fi

branch_exists=false
diff_text=""
diff_error=""
if git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
  branch_exists=true
  if diff_text="$(git -C "$proj" diff "$base...$branch" -- 2>&1)"; then
    diff_error=""
  else
    diff_error="$diff_text"
    diff_text=""
  fi
fi

jq -n \
  --arg id "$id" \
  --arg branch "$branch" \
  --arg base "$base" \
  --argjson branch_exists "$branch_exists" \
  --argjson status "$status_json" \
  --arg diff "$diff_text" \
  --arg error "$diff_error" \
  '{id: $id, branch: $branch, base: $base, branch_exists: $branch_exists,
    status: $status, diff: $diff}
   + (if ($error | length) > 0 then {error: $error} else {} end)'

if [ "$branch_exists" = false ]; then
  echo "collect: branch $branch does not exist" >&2
  exit 1
fi
[ -z "$diff_error" ] || exit 1
exit 0
