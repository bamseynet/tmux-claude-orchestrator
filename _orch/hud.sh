#!/usr/bin/env bash
# _orch/hud.sh — renders "w1:working w2:blocked w3:done" for the tmux status bar.
# Called every few seconds by status-right.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh" 2>/dev/null || true
shopt -s nullglob

out=""
for f in "$WORKERS_DIR"/*.json; do
  id="$(basename "$f" .json)"
  st="$(jq -r '.status // "?"' "$f" 2>/dev/null)"
  case "$st" in
    blocked|needs-input|error) c="#[fg=red,bold]" ;;
    done|subagent-done)        c="#[fg=green]" ;;
    working|spawning)          c="#[fg=yellow]" ;;
    *)                         c="#[fg=white]" ;;
  esac
  out+="${c}${id}:${st}#[default] "
done
[ -z "$out" ] && out="#[fg=colour244]no workers#[default]"
printf '%s' "$out"
