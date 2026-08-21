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

mkdir -p "$target/.claude"

# Idempotent update: preserve the target's own config.json (thresholds/budget the
# user has already tuned) across a re-install, instead of overwriting it with the
# source defaults every time.
cfg_backup=""
[ -f "$target/_orch/config.json" ] && cfg_backup="$(cat "$target/_orch/config.json")"

# The persisted session name (issue #92) is per-install identity, not
# throwaway runtime state -- an operator's `--name` pin must survive an
# upgrade the same way config.json already does, or a re-install silently
# reverts a named session back to the orch-<hash> default underneath it.
name_backup=""
[ -f "$target/_orch/state/session-name" ] && name_backup="$(cat "$target/_orch/state/session-name")"

cp -R "$src/_orch" "$target/"
cp -R "$src/tmux" "$target/"
cp "$src/orch" "$target/"
chmod +x "$target/orch" "$target/_orch/"*.sh
rm -rf "$target/_orch/state"   # never copy runtime state

if [ -n "$cfg_backup" ]; then
  printf '%s' "$cfg_backup" > "$target/_orch/config.json"
  echo "  . preserved existing $target/_orch/config.json"
fi

if [ -n "$name_backup" ]; then
  mkdir -p "$target/_orch/state"
  printf '%s' "$name_backup" > "$target/_orch/state/session-name"
  echo "  . preserved existing session name ($name_backup)"
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
