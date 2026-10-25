#!/usr/bin/env bash
# _orch/master-session-start.sh — SessionStart hook for the master (issue #159).
# Always records the new session_id to $STATE_DIR/master-session.json. On
# source clear|compact it also emits additionalContext: the role prompt followed
# by rehydrate.sh output, truncated to 9,500 chars (hook output is capped at
# 10,000). On startup/resume bootstrap already sent the role prompt, so nothing
# is emitted. Always exits 0.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/lib.sh" 2>/dev/null || exit 0

input="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
src="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null || true)"

if [ -n "$sid" ]; then
  tmp="$STATE_DIR/master-session.json.tmp.$$"
  if jq -nc --arg s "$sid" --arg src "$src" --arg ts "$(date -u +%FT%TZ)" \
       '{session_id:$s, source:$src, ts:$ts}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE_DIR/master-session.json" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
fi

case "$src" in
  clear|compact)
    summary="$("$here/rehydrate.sh" 2>/dev/null || true)"
    jq -nc --arg c "$(master_role_prompt)

$summary" \
      '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c[0:9500]}}' 2>/dev/null || true
    ;;
esac
exit 0
