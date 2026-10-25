#!/usr/bin/env bash
# _orch/master-statusline.sh — the master's Claude Code status line (issue #159).
# Reads the status-line JSON on stdin once, records context usage atomically to
# $STATE_DIR/master-context.json, then chains to the operator's own
# statusLine.command (--settings replaces it) or prints a minimal line.
# Must always exit 0 and never print the glyphs the pane heuristics match on.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Deliberately does NOT source lib.sh: this runs on every status-line refresh and
# lib.sh's load-time work (a dozen jq/sha1sum subprocesses) is pure overhead
# here. The path is pinned to THIS toolkit, not an inherited $ORCH_ROOT.
input="$(cat 2>/dev/null || true)"
out="$here/state/master-context.json"

# tokens = what is in the window NOW (current_usage, the last API call), not
# total_input_tokens, which is cumulative across the session and overshoots the
# window after a few turns; fall back to it only on CLIs that lack the
# current_usage KEY -- a present-but-null current_usage (no API call yet since a
# /clear or compaction) means "unknown", not "use the cumulative total".
# The previous record, so .first (this session's FIRST real reading -- the
# post-/clear floor the #160 loop guard judges) survives later refreshes.
prev="$(jq -c 'select(type == "object")' "$out" 2>/dev/null || true)"
rec="$(printf '%s' "$input" | jq -c --argjson prev "${prev:-null}" '
  select(type == "object")
  | (.context_window // {}) as $cw
  | ($cw.current_usage // null) as $u
  | (($cw | type) == "object" and ($cw | has("current_usage"))) as $has_cu
  | {pct: $cw.used_percentage,
     tokens: (if ($u | type) == "object"
              then (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0))
              elif $has_cu then null
              else $cw.total_input_tokens end),
     window: $cw.context_window_size, session_id: .session_id,
     ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
     reset: (($u == null) and $has_cu)}
  # A present-but-null current_usage (just after a /clear or compaction) is
  # recorded as unknown rather than skipped, so the pre-compaction usage does
  # not linger in the file as if it were still current.
  | select((.pct // 0) != 0 or (.tokens // 0) != 0 or .reset)
  | .first = (if ($prev | type) == "object" and $prev.session_id == .session_id and $prev.first != null
              then $prev.first
              elif .tokens != null or .pct != null then {pct, tokens}
              else null end)
  | del(.reset)' 2>/dev/null || true)"
if [ -n "$rec" ]; then
  tmp="$out.tmp.$$"
  if printf '%s\n' "$rec" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
fi

# --settings outranks every other layer, so chain to the operator's bar from the
# highest-precedence layer that defines one: project-local, project, then user.
user_cmd=""
for _f in "$PWD/.claude/settings.local.json" "$PWD/.claude/settings.json" \
          "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
  user_cmd="$(jq -r '.statusLine.command // empty' "$_f" 2>/dev/null || true)"
  [ -n "$user_cmd" ] && break
done
# Never chain to ourselves (an operator who copied this into their own settings).
case "$user_cmd" in *master-statusline.sh*) user_cmd="" ;; esac
if [ -n "$user_cmd" ]; then
  # The operator's bar may print prompt/box glyphs (❯ > │ ...) that
  # TUI_READY_REGEX / pane_has_draft would match, or spinner glyphs
  # (✻ ✽ ✳ ✶) that TUI_ACTIVE_GLYPH_REGEX reads as "busy", or the words
  # is_busy() greps for case-insensitively (TUI_BUSY_REGEX: "esc to interrupt",
  # "Running…", "Compacting") -- any of those would pin the master as busy
  # forever -- or TUI_READY_REGEX's words ("for shortcuts", 'Try "') that fake
  # an input box, or "Welcome" (TUI_WELCOME_REGEX, -i) that makes
  # inject_confirmed() read a landed prompt as dropped; neutralise them.
  # Character classes, not sed's GNU-only I flag.
  printf '%s' "$input" | bash -c "$user_cmd" 2>/dev/null \
    | sed -e 's/❯/-/g' -e 's/>/-/g' -e 's/│/|/g' -e 's/┃/|/g' -e 's/╭/+/g' -e 's/╮/+/g' -e 's/╰/+/g' -e 's/╯/+/g' \
        -e 's/✻/*/g' -e 's/✽/*/g' -e 's/✳/*/g' -e 's/✶/*/g' -e 's/…/.../g' \
        -e 's/\([Cc][Oo][Mm][Pp][Aa][Cc][Tt]\)\([Ii][Nn][Gg]\)/\1-\2/g' \
        -e 's/\([Ee][Ss][Cc]\) \([Tt][Oo] [Ii][Nn][Tt][Ee][Rr][Rr][Uu][Pp][Tt]\)/\1-\2/g' \
        -e 's/for shortcuts/for-shortcuts/g' -e 's/Try "/Try-"/g' \
        -e 's/\([Ww][Ee][Ll]\)\([Cc][Oo][Mm][Ee]\)/\1-\2/g' || true
else
  pct="$(printf '%s' "$rec" | jq -r '.pct // empty' 2>/dev/null || true)"
  if [ -n "$pct" ]; then printf 'orch master ctx %s%%\n' "$pct"; else printf 'orch master\n'; fi
fi
exit 0
