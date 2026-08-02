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
    queued)                    c="#[fg=cyan]" ;;
    *)                         c="#[fg=white]" ;;
  esac
  out+="${c}${id}:${st}#[default] "
done
[ -z "$out" ] && out="#[fg=colour244]no workers#[default]"

# Coarse per-session spend estimate (issue #24): spawns * budget.est_usd_per_worker,
# against the configured cap. Purely informational — not exact token metering.
budget_out=""
if [ -f "$here/config.json" ]; then
  budget_max="$(jq -r '.budget.max_usd // empty' "$here/config.json" 2>/dev/null)"
  if [ -n "$budget_max" ]; then
    spent="$(est_spend_usd 2>/dev/null || echo 0)"
    budget_out="#[fg=colour244]~\$${spent}/\$${budget_max}#[default] "
  fi
fi

printf '%s' "${budget_out}${out}"
