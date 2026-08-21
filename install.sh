#!/usr/bin/env bash
# install.sh [TARGET_REPO_DIR]
# Copies the orchestrator toolkit into a target git repo and writes a local Claude
# settings file (teams enabled + permission allowlist for the master). Defaults to cwd.
# Safe to re-run against an already-installed target: it's an idempotent update that
# preserves the target's own _orch/config.json (thresholds/budget tuning) instead of
# clobbering it with the source defaults.
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-$(pwd)}"
version="$(cat "$src/VERSION" 2>/dev/null || echo unknown)"
prev_version=""
[ -f "$target/.orch-version" ] && prev_version="$(cat "$target/.orch-version")"

if [ -n "$prev_version" ] && [ "$prev_version" != "$version" ]; then
  echo "Updating orchestrator toolkit in: $target ($prev_version -> $version)"
elif [ -n "$prev_version" ]; then
  echo "Re-installing orchestrator toolkit in: $target (already at $version)"
else
  echo "Installing orchestrator toolkit into: $target ($version)"
fi

for dep in tmux jq claude perl git; do
  if ! command -v "$dep" >/dev/null; then
    echo "  ! missing dependency: $dep (install it before running)"
  fi
done

if [ ! -d "$target/.git" ]; then
  echo "  ! $target is not a git repo root. Worktrees need a git repo."
  echo "    Run this from your project root, or pass the path: ./install.sh /path/to/repo"
fi

mkdir -p "$target/.claude" "$target/_orch" "$target/tmux"

# --- Atomic, state-preserving copy --------------------------------------------
# A plain `cp -R` overwrites each destination file IN PLACE, reusing its
# existing inode. bash (and any other running script) re-reads an executing
# script by byte offset from that same inode, so a script this install.sh
# rewrites while it (or another _orch/*.sh) is still running mid-execution can
# resume at a shifted offset into different content, or crash, or run an
# arbitrary fragment — a real failure mode reproduced against a vendored
# install, not theoretical. Fix: build the ENTIRE new tree in a scratch
# staging dir first — a failure while staging (e.g. a future upstream
# missing a directory this version expects) never touches the target at all,
# so a partial/broken checkout never happens — then swap files into place one
# at a time via `mv` on the SAME filesystem, which is an atomic rename: the
# target path gets a NEW inode while anything already reading the OLD file
# keeps its own open handle to the old inode's original, untouched bytes
# until it closes it. `trap ... EXIT` guarantees the staging dir never leaks,
# on either success or failure.
#
# The swap set is exactly $src's tree (_orch/*, tmux/*, orch) MINUS
# _orch/config.json and MINUS _orch/state entirely:
#   - config.json: swapped in only when the target has none yet (fresh
#     install). An EXISTING target config.json is never staged, never
#     touched, by either phase — so the user's tuned thresholds/budget
#     survive even a totally failed update, not just a successful one (the
#     previous copy-defaults-then-restore-backup approach had a window,
#     between overwriting config.json with defaults and restoring the saved
#     copy over it, where any failure left the defaults clobbering the
#     user's tuning with no state file even naming what happened).
#   - _orch/state: never part of $src's shipped tree and never referenced by
#     this copy at all (no `rm -rf` of it, unlike before) — so an update
#     never destroys events.jsonl (the durable event history), spend.json
#     (the budget guard), queue.jsonl (queued-not-dropped spawns),
#     master-notes.md, the session-owner marker, or heartbeat/watchdog pids.
#     A fresh install still gets a clean target because nothing pre-exists
#     under _orch/state to preserve or destroy either way.
stage="$(mktemp -d "$target/.orch-install-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/_orch" "$stage/tmux"
cp -R "$src/_orch/." "$stage/_orch/"
cp -R "$src/tmux/." "$stage/tmux/"
cp "$src/orch" "$stage/orch"
rm -rf "$stage/_orch/state"   # defensive: never stage runtime state either
have_cfg=0
[ -f "$target/_orch/config.json" ] && have_cfg=1
[ "$have_cfg" = 1 ] && rm -f "$stage/_orch/config.json"
chmod +x "$stage/orch" "$stage/_orch/"*.sh

while IFS= read -r -d '' f; do
  rel="${f#"$stage"/}"
  destf="$target/$rel"
  mkdir -p "$(dirname "$destf")"
  mv -f "$f" "$destf"
done < <(find "$stage" -type f -print0)

if [ "$have_cfg" = 1 ]; then
  echo "  . preserved existing $target/_orch/config.json"
fi

# The persisted session name (issue #92) is per-install identity, not
# throwaway runtime state -- an operator's `--name` pin must survive an
# upgrade the same way config.json does. Unlike config.json this needs no
# backup/restore dance: _orch/state is never part of the swap set above (see
# the block comment on the staged copy), so an existing session-name file is
# simply never touched in the first place. Still surface the same
# "preserved" signal nm's install.sh change relied on, for consistency.
if [ -f "$target/_orch/state/session-name" ]; then
  echo "  . preserved existing session name ($(cat "$target/_orch/state/session-name"))"
fi

echo "$version" > "$target/.orch-version"

# Orchestrator (master) settings: enable teams + allow it to drive tmux and the toolkit.
settings="$target/.claude/settings.local.json"
if [ -f "$settings" ]; then
  echo "  . $settings exists — leaving it. Merge these keys yourself if needed:"
  echo '    env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 ; teammateMode=tmux ; permissions.allow[Bash(...)]'
else
  cat > "$settings" <<'JSON'
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "teammateMode": "tmux",
  "permissions": {
    "allow": [
      "Bash(tmux:*)",
      "Bash(./orch:*)",
      "Bash(./_orch/*.sh:*)",
      "Bash(git worktree:*)",
      "Read(./_orch/state/**)"
    ]
  }
}
JSON
  echo "  + wrote $settings"
fi

# gitignore runtime + worker state
gi="$target/.gitignore"
touch "$gi"
for line in "_orch/state/" "wt/" ".claude/settings.local.json"; do
  grep -qxF "$line" "$gi" || echo "$line" >> "$gi"
done

cat <<EOF

Done. Next:
  cd "$target"
  ./orch up            # starts the master + background loops
  ./orch attach        # watch it (master in window 0, workers get their own windows)

Then, inside the master session, give it tasks — or from another shell:
  ./orch spawn w1 sonnet "Implement X in module A"
  ./orch status
EOF
