#!/usr/bin/env bash
# _orch/guard-write.sh <worker-id> <target-repo> <worktree>
# Worker PreToolUse hook (issue #152) on Edit|Write|MultiEdit|NotebookEdit.
# Reads the hook JSON on stdin and denies (exit 2, reason on stderr) a write whose
# path is under the target repo but outside the worker's own worktree -- the
# worker would be editing the shared checkout (the live toolkit when target ==
# ORCH_ROOT). Paths elsewhere (scratchpad, /tmp) are allowed. Fails open on an
# unparseable payload so it can never wedge a worker. Bash-made writes bypass
# this hook; that is the heartbeat backstop's job.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?worker id}"; proj="${2:?target repo}"; wdir="${3:?worktree}"

payload=""
IFS= read -r -d '' -t 5 payload 2>/dev/null || true
path="$(printf '%s' "$payload" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)" || exit 0
[ -n "$path" ] || exit 0

# Lexical normalisation (the file may not exist yet): resolve ".", ".." and "//".
# Globbing is off so a path segment such as "*" or "[ab]" is never expanded.
set -f
norm() {
  local p="$1" out="" seg
  local IFS=/
  for seg in $p; do
    case "$seg" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}
# Physical form: Claude Code reports physical (symlink-resolved) paths, while spawn
# passes the logical `pwd` of the target repo and "$proj/../wt/..." for the
# worktree. Comparing lexically would let a symlinked repo path bypass the guard,
# so resolve the longest existing ancestor with cd -P and re-append the rest.
canon() {
  local p d rest=""
  p="$(norm "$1")"; d="$p"
  while [ "$d" != / ] && [ ! -d "$d" ]; do
    rest="/${d##*/}$rest"; d="${d%/*}"; [ -n "$d" ] || d=/
  done
  d="$(_phys_dir "$d")" || { printf '%s' "$p"; return 0; }
  [ "$d" = / ] && d=""
  p="$d$rest"; printf '%s' "${p:-/}"
}
under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

case "$path" in /*) ;; *) path="$wdir/$path" ;; esac
path="$(canon "$path")"; proj="$(canon "$proj")"; wdir="$(canon "$wdir")"

under "$path" "$proj" || exit 0
under "$path" "$wdir" && exit 0

printf '{"id":"%s","event":"write-outside-worktree","path":%s,"ts":"%s"}\n' \
  "$id" "$(printf '%s' "$path" | jq -Rs .)" "$(date -u +%FT%TZ)" >> "$STATE_DIR/events.jsonl"
echo "orch: worker $id may not write $path -- it is in the target repo's main checkout, outside your worktree $wdir. Use the same relative path under $wdir." >&2
exit 2
