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
# That ancestor is resolved BEFORE lexical normalisation: "<symlink>/../x" must
# climb the symlink's target (see _phys_dir), so only the non-existent tail -- which
# holds no symlinks -- is normalised lexically.
# A symlinked final component (cd -P only resolves dirs) is followed with plain
# readlink, hop by hop, so "<wdir>/link -> <proj>/f" cannot write through.
canon() {
  local p="$1" d rest="" t n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ] && t="$(readlink -- "$p")"; do
    case "$t" in /*) p="$t" ;; *) p="${p%/*}/$t" ;; esac; n=$((n + 1))
  done
  d="$p"
  while [ "$d" != / ] && [ ! -d "$d" ]; do
    rest="/${d##*/}$rest"; d="${d%/*}"; [ -n "$d" ] || d=/
  done
  d="$(_phys_dir "$d")" || { norm "$p"; return 0; }
  norm "$d$rest"
}
under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

case "$path" in /*) ;; *) path="$wdir/$path" ;; esac
path="$(canon "$path")"; proj="$(canon "$proj")"; wdir="$(canon "$wdir")"

under "$path" "$proj" || exit 0
under "$path" "$wdir" && exit 0

# Dual-write (like every other emitter) so the heartbeat tells the master too.
if line="$(jq -nc --arg id "$id" --arg p "$path" --arg ts "$(date -u +%FT%TZ)" \
    '{id:$id, event:"write-outside-worktree", path:$p, ts:$ts}')"; then
  printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
  printf '%s\n' "$line" >> "$INBOX"
fi
echo "orch: worker $id may not write $path -- it is in the target repo's main checkout, outside your worktree $wdir. Use the same relative path under $wdir." >&2
exit 2
