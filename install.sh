#!/usr/bin/env bash
# install.sh [TARGET_REPO_DIR]
# Copies the orchestrator toolkit into a target git repo and writes a local Claude
# settings file (teams enabled + permission allowlist for the master). Defaults to cwd.
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-$(pwd)}"

echo "Installing orchestrator toolkit into: $target"

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
cp -R "$src/_orch" "$target/"
cp -R "$src/tmux" "$target/"
cp "$src/orch" "$target/"
chmod +x "$target/orch" "$target/_orch/"*.sh
rm -rf "$target/_orch/state"   # never copy runtime state

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
