#!/usr/bin/env bash
# _orch/hud.sh — renders "w1:working w2:blocked w3:done" for the tmux status bar.
# Called every few seconds by status-right.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh" 2>/dev/null || true
shopt -s nullglob

# age (issue #17): elapsed time since `created` (falling back to `updated` for
# status files written before this issue), rendered coarsely (Xs/Xm/XhYm/XdYh).
age_str() { # <iso8601-utc-ts>
  local ts="$1" epoch now secs
  [ -n "$ts" ] && [ "$ts" != "null" ] || { echo ""; return; }
  epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || { echo ""; return; }
  now="$(date -u +%s)"
  secs=$((now - epoch))
  [ "$secs" -lt 0 ] && secs=0
  if [ "$secs" -lt 60 ]; then
    printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm' $((secs / 60))
  elif [ "$secs" -lt 86400 ]; then
    printf '%dh%dm' $((secs / 3600)) $(((secs % 3600) / 60))
  else
    printf '%dd%dh' $((secs / 86400)) $(((secs % 86400) / 3600))
  fi
}

out=""
for f in "$WORKERS_DIR"/*.json; do
  id="$(basename "$f" .json)"
  st="$(jq -r '.status // "?"' "$f" 2>/dev/null)"
  ts="$(jq -r '.created // .updated // empty' "$f" 2>/dev/null)"
  age="$(age_str "$ts")"
  case "$st" in
    blocked|needs-input|error) c="#[fg=red,bold]" ;;
    done|subagent-done)        c="#[fg=green]" ;;
    working|spawning)          c="#[fg=yellow]" ;;
    queued)                    c="#[fg=cyan]" ;;
    *)                         c="#[fg=white]" ;;
  esac
  out+="${c}${id}:${st}${age:+:${age}}#[default] "
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

# Queue depth (issue #79): a queue nobody can see is a queue nobody maintains.
queue_out=""
if [ -s "${QUEUE:-}" ]; then
  queue_out="#[fg=cyan]q:$(wc -l < "$QUEUE" | tr -d ' ')#[default] "
fi

printf '%s' "${budget_out}${queue_out}${out}"
