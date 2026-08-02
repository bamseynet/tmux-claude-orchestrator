#!/usr/bin/env bash
# uninstall.sh [TARGET_REPO_DIR]
# Removes the orchestrator toolkit files that install.sh copied into a target repo:
# _orch/, tmux/, orch, and .orch-version. Idempotent — safe to run again on an
# already-uninstalled target. Does NOT touch git worktrees under ../wt, running
# tmux sessions, or the target's own git history — stop workers first
# (`./orch down`) and clean up worktrees (`./orch clean <id>`) if needed. Leaves
# .claude/settings.local.json in place since it may hold other project settings;
# remove it yourself if you no longer want it.
set -euo pipefail
target="${1:-$(pwd)}"

if [ ! -d "$target/_orch" ] && [ ! -f "$target/orch" ] && [ ! -d "$target/tmux" ]; then
  echo "Nothing to uninstall: no _orch/, orch, or tmux/ found in $target"
  exit 0
fi

echo "Uninstalling orchestrator toolkit from: $target"

rm -rf "$target/_orch" "$target/tmux"
rm -f "$target/orch" "$target/.orch-version"
echo "  - removed _orch/, tmux/, orch, .orch-version"

settings="$target/.claude/settings.local.json"
if [ -f "$settings" ]; then
  echo "  . leaving $settings in place (may hold other project settings) — remove manually if desired"
fi

# Trim the gitignore lines install.sh added, if present.
gi="$target/.gitignore"
if [ -f "$gi" ]; then
  tmp="$(mktemp)"
  grep -vxF -e "_orch/state/" -e "wt/" -e ".claude/settings.local.json" "$gi" > "$tmp" || true
  mv "$tmp" "$gi"
  echo "  - trimmed toolkit entries from $gi"
fi

echo
echo "Done. Toolkit files removed from $target."
