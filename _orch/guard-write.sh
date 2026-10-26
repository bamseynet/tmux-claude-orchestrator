#!/usr/bin/env bash
# _orch/guard-write.sh <worker-id> <target-repo> <worktree>
# Worker PreToolUse hook (issue #152) on Edit|Write|MultiEdit|NotebookEdit.
# Reads the hook JSON on stdin and denies (exit 2, reason on stderr) a write whose
# path is under the target repo but outside the worker's own worktree -- the
# worker would be editing the shared checkout (the live toolkit when target ==
# ORCH_ROOT). Paths elsewhere (scratchpad, /tmp) are allowed. Fails open on an
# unparseable payload so it can never wedge a worker. Bash-made writes bypass
# this hook; catching them needs a heartbeat dirtiness check (#152 direction 2),
# which is not implemented yet.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh"

id="${1:?worker id}"; proj="${2:?target repo}"; wdir="${3:?worktree}"

# jq reads the hook's stdin directly: bash `read` drains a pipe one byte per
# syscall, so a large Write payload (~1 MB) outran any read timeout and the
# truncated JSON then failed open. Bounded by `timeout` where present, so a stdin
# that never closes fails open instead of stalling the worker on the hook timeout.
tmo=(); command -v timeout >/dev/null 2>&1 && tmo=(timeout 10)
# Line 1 is the session cwd (a relative file_path resolves against it, and a Bash
# `cd` moves it off the worktree root); the rest is the path. No newline -> no path.
out="$("${tmo[@]}" jq -r '(.cwd // "" | tostring), (.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)" || exit 0
case "$out" in *$'\n'*) ;; *) exit 0 ;; esac
cwd="${out%%$'\n'*}"; path="${out#*$'\n'}"
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
# climb the symlink's target (see _phys_dir), so only the non-existent tail is
# normalised lexically.
# The walk also stops at a symlink that is not a directory (a link to a file, or a
# dangling link -- cd -P cannot resolve either): it is followed with readlink and
# the result re-canonicalised, so "<wdir>/link -> <proj>/f" and
# "<wdir>/dangling -> <proj>/newdir" cannot write through.
# A tail holding ".." ("<wdir>/missing/../link") is covered by the lexical
# candidate below (norm first, then canon), which follows the link it names.
# Hops are capped at 40 (a link loop then falls back to lexical form).
canon() {
  local p="$1" n="${2:-0}" d="$1" rest="" t
  [ "$n" -lt 40 ] || { norm "$p"; return 0; }
  while [ "$d" != / ] && [ ! -d "$d" ] && [ ! -L "$d" ]; do
    rest="/${d##*/}$rest"; d="${d%/*}"; [ -n "$d" ] || d=/
  done
  if [ ! -d "$d" ] && t="$(readlink -- "$d")"; then
    case "$t" in /*) ;; *) t="${d%/*}/$t" ;; esac
    canon "$t$rest" $((n + 1)); return 0
  fi
  d="$(_phys_dir "$d")" || { norm "$p"; return 0; }
  norm "$d$rest"
}
under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

proj="$(canon "$proj")"; wdir="$(canon "$wdir")"
# Claude Code expands a leading "~" in file_path (expandPath) before writing, so
# "~/<repo>/x" must be read against $HOME, not as a relative "<wdir>/~/..." path.
# shellcheck disable=SC2088  # matching a literal "~", not expanding one
case "$path" in
  "~") path="$HOME" ;;
  "~/"*) path="$HOME/${path#"~/"}" ;;
esac
case "$cwd" in /*) ;; *) cwd="$wdir" ;; esac
case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
# Two readings of the same string: the kernel's (symlinks before "..", canon) and a
# writer that normalises the string first (path.resolve), whose ".." pops a symlink
# lexically ("<target>/<link-out>/../x" is <target>/x). Deny if either lands in the
# main checkout outside the worktree.
lex="$(norm "$path")"
cands=("$(canon "$path")")
[ "$lex" = "$path" ] || cands+=("$(canon "$lex")")   # same string -> same reading
for cand in "${cands[@]}"; do
  under "$cand" "$proj" && ! under "$cand" "$wdir" && { path="$cand"; break; }
  cand=""
done
[ -n "$cand" ] || exit 0

# Dual-write (like every other emitter) so the heartbeat tells the master too.
if line="$(jq -nc --arg id "$id" --arg p "$path" --arg ts "$(date -u +%FT%TZ)" \
    '{id:$id, event:"write-outside-worktree", path:$p, ts:$ts}')"; then
  printf '%s\n' "$line" >> "$STATE_DIR/events.jsonl"
  printf '%s\n' "$line" >> "$INBOX"
fi
echo "orch: worker $id may not write $path -- it is in the target repo's main checkout, outside your worktree $wdir. Use the same relative path under $wdir." >&2
exit 2
