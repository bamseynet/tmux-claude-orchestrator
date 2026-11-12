#!/usr/bin/env bash
# _orch/worker-statusline.sh <id> <skip-settings-path> — a worker's Claude Code
# status line (issue #210). Reads the status-line JSON on stdin once, records
# context usage atomically to $here/state/worker-context/<id>.json, then CHAINS
# to the next-lower settings layer's statusLine so the operator's own bar keeps
# rendering. <skip-settings-path> is the file this command lives in (spawn's
# settings.local.json, or the private --settings file): it is never chained to.
# RECORD ONLY: crossing detection/events live in heartbeat.sh worker_context_tick.
# Must always exit 0, never source lib.sh (runs on every refresh), and never
# print the glyphs/words the pane heuristics match on.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="${1:-}"
skip="${2:-}"
input="$(cat 2>/dev/null || true)"

# The id becomes a file name: only the characters spawn.sh allows in an id.
case "$id" in
  ''|*[!A-Za-z0-9._-]*|.|..|.*) id="" ;;
esac

if [ -n "$id" ]; then
  dir="$here/state/worker-context"
  out="$dir/$id.json"
  # Same derivation as master-statusline.sh: tokens = current_usage (what is in
  # the window now), not the cumulative total; a present-but-null current_usage
  # (after /clear or compaction) is .reset = unknown, not a reading.
  rec="$(printf '%s' "$input" | jq -c '
    select(type == "object")
    | (.context_window // {}) as $cw
    | ($cw.current_usage // null) as $u
    | (($cw | type) == "object" and ($cw | has("current_usage"))) as $has_cu
    | (if ($u | type) == "object"
       then (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0))
       else null end) as $cur
    # No used_percentage: derive it from current_usage / window (never from the
    # cumulative total_input_tokens), as the master tick does from tokens/window;
    # otherwise the heartbeat (numeric pct only) would never warn this worker.
    | {pct: ($cw.used_percentage
             // (if $cur != null and (($cw.context_window_size | type) == "number") and $cw.context_window_size > 0
                 then ($cur * 100 / $cw.context_window_size | floor) else null end)),
       tokens: (if $cur != null then $cur
                elif $has_cu then null
                else $cw.total_input_tokens end),
       window: $cw.context_window_size, session_id: .session_id,
       ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
       reset: (($u == null) and $has_cu)}
    | select((.pct // 0) != 0 or (.tokens // 0) != 0 or .reset)' 2>/dev/null || true)"
  if [ -n "$rec" ] && mkdir -p "$dir" 2>/dev/null; then
    tmp="$out.tmp.$$"
    if printf '%s\n' "$rec" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
  fi
fi

# Chain to the highest-precedence layer BELOW ours that defines a statusLine.
# Unlike master-statusline.sh we skip (not stop at) our own layer: spawn's
# settings.local.json is the top layer here, so master's "first hit, then
# blank" logic would drop the repo and user bars.
user_cmd=""
for _f in "$PWD/.claude/settings.local.json" "$PWD/.claude/settings.json" \
          "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
  [ -f "$_f" ] || continue
  [ -n "$skip" ] && [ "$_f" -ef "$skip" ] && continue
  c="$(jq -r '.statusLine.command // empty' "$_f" 2>/dev/null || true)"
  [ -n "$c" ] || continue
  case "$c" in *worker-statusline.sh*|*master-statusline.sh*) continue ;; esac
  user_cmd="$c"
  break
done
if [ -n "$user_cmd" ]; then
  # Neutralise what TUI_READY/ACTIVE/BUSY/WELCOME regexes match (see
  # master-statusline.sh for the full reasoning).
  printf '%s' "$input" | bash -c "$user_cmd" 2>/dev/null \
    | sed -e 's/❯/-/g' -e 's/>/-/g' -e 's/│/|/g' -e 's/┃/|/g' -e 's/╭/+/g' -e 's/╮/+/g' -e 's/╰/+/g' -e 's/╯/+/g' \
        -e 's/✻/*/g' -e 's/✽/*/g' -e 's/✳/*/g' -e 's/✶/*/g' -e 's/…/.../g' \
        -e 's/\([Cc][Oo][Mm][Pp][Aa][Cc][Tt]\)\([Ii][Nn][Gg]\)/\1-\2/g' \
        -e 's/\([Ee][Ss][Cc]\) \([Tt][Oo] [Ii][Nn][Tt][Ee][Rr][Rr][Uu][Pp][Tt]\)/\1-\2/g' \
        -e 's/for shortcuts/for-shortcuts/g' -e 's/Try "/Try-"/g' \
        -e 's/\([Ww][Ee][Ll]\)\([Cc][Oo][Mm][Ee]\)/\1-\2/g' || true
else
  pct="$(printf '%s' "${rec:-}" | jq -r '.pct // empty' 2>/dev/null || true)"
  if [ -n "$pct" ]; then printf 'ctx %s%%\n' "$pct"; else printf 'worker\n'; fi
fi
exit 0
