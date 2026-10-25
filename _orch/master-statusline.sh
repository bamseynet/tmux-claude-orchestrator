#!/usr/bin/env bash
# _orch/master-statusline.sh — the master's Claude Code status line (issue #159).
# Reads the status-line JSON on stdin once, records context usage atomically to
# $STATE_DIR/master-context.json, then chains to the operator's own
# statusLine.command (--settings replaces it) or prints a minimal line.
# Must always exit 0 and never print the glyphs the pane heuristics match on.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh" 2>/dev/null || true

input="$(cat 2>/dev/null || true)"
out="${STATE_DIR:-$here/state}/master-context.json"

rec="$(printf '%s' "$input" | jq -c --arg ts "$(date -u +%FT%TZ)" '
  select(type == "object")
  | {pct: .context_window.used_percentage, tokens: .context_window.total_input_tokens,
     window: .context_window.context_window_size, session_id: .session_id, ts: $ts}
  | select((.pct // 0) != 0 or (.tokens // 0) != 0)' 2>/dev/null || true)"
if [ -n "$rec" ]; then
  tmp="$out.tmp.$$"
  if printf '%s\n' "$rec" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
fi

user_cmd="$(jq -r '.statusLine.command // empty' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"
if [ -n "$user_cmd" ]; then
  # The operator's bar may print prompt/box glyphs (❯ > │ ...) that
  # TUI_READY_REGEX / pane_has_draft would match; neutralise them.
  printf '%s' "$input" | bash -c "$user_cmd" 2>/dev/null \
    | sed -e 's/❯/-/g' -e 's/>/-/g' -e 's/│/|/g' -e 's/┃/|/g' -e 's/╭/+/g' -e 's/╮/+/g' -e 's/╰/+/g' -e 's/╯/+/g' || true
else
  pct="$(printf '%s' "$rec" | jq -r '.pct // empty' 2>/dev/null || true)"
  if [ -n "$pct" ]; then printf 'orch master ctx %s%%\n' "$pct"; else printf 'orch master\n'; fi
fi
exit 0
