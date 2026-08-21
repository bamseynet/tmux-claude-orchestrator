# Shared fake-tmux fixture (issue #121).
#
# One `tmux` implementation for the whole bats suite, instead of a dozen-plus
# independent per-file stubs that drift from real tmux in different ways --
# see issue #121 for the three failures that drift caused in one day (exact
# vs prefix matching, flags silently ignored vs rejected, missing
# list-sessions).
#
# State lives on disk under $FAKE_TMUX_STATE, NOT in shell variables, so the
# exact same implementation works whether a test sources this file and calls
# the `tmux` function directly (in-process, e.g. `source watchdog.sh`), or a
# test installs it as a PATH stub via fake_tmux_install_stub and the toolkit
# invokes `tmux` as a real subprocess -- both paths read/write the same files.
#
#   $FAKE_TMUX_STATE/sessions/<name>/windows/<index>:<winname>   -- existence = window exists
#   $FAKE_TMUX_STATE/sessions/<name>/panes/<winname>             -- capture-pane content
#   $FAKE_TMUX_STATE/sessions/<name>/sendkeys.log                -- send-keys/paste-buffer log
#   $FAKE_TMUX_STATE/buffers/<name>                              -- load-buffer/paste-buffer/show-buffer
#   $FAKE_TMUX_STATE/reject-capture-e                            -- if present, capture-pane -e fails
#
# Per-test customisation (per the issue: "override ONE subcommand on top of
# the shared base without forking the whole thing"): define a function named
# fake_tmux_override_<subcommand-with-dashes-as-underscores> AFTER sourcing
# this file, e.g. `fake_tmux_override_send_keys() { ... }`. The dispatcher
# below calls it instead of the built-in behaviour, with the same argv (minus
# the subcommand word) that real tmux would have received.

: "${FAKE_TMUX_STATE:?fake-tmux.bash: set FAKE_TMUX_STATE before sourcing (e.g. \$BATS_TEST_TMPDIR/fake-tmux-state)}"

fake_tmux_init() {
  mkdir -p "$FAKE_TMUX_STATE/sessions" "$FAKE_TMUX_STATE/buffers"
}
fake_tmux_init

# --- helpers used by tests to set up / inspect fixture state -----------------------

fake_tmux_add_session() { # <name> [window-name=orchestrator]
  local name="$1" win="${2:-orchestrator}"
  mkdir -p "$FAKE_TMUX_STATE/sessions/$name/windows" "$FAKE_TMUX_STATE/sessions/$name/panes"
  : > "$FAKE_TMUX_STATE/sessions/$name/windows/0:$win"
  : > "$FAKE_TMUX_STATE/sessions/$name/sendkeys.log"
}

fake_tmux_add_window() { # <session> <winname> [index]
  local sess="$1" win="$2" idx="${3:-}"
  mkdir -p "$FAKE_TMUX_STATE/sessions/$sess/windows"
  if [ -z "$idx" ]; then
    idx=0
    local existing
    while true; do
      existing=0
      for existing in "$FAKE_TMUX_STATE/sessions/$sess/windows/$idx:"*; do
        [ -e "$existing" ] && existing=1 || existing=0
        break
      done
      [ "$existing" -eq 1 ] || break
      idx=$((idx + 1))
    done
  fi
  : > "$FAKE_TMUX_STATE/sessions/$sess/windows/$idx:$win"
}

fake_tmux_set_pane() { # <session> <winname> <content>
  mkdir -p "$FAKE_TMUX_STATE/sessions/$1/panes"
  printf '%s' "$3" > "$FAKE_TMUX_STATE/sessions/$1/panes/$2"
}

fake_tmux_sendkeys_log() { # <session> -> log contents
  cat "$FAKE_TMUX_STATE/sessions/$1/sendkeys.log" 2>/dev/null
}

fake_tmux_reject_capture_e() { # simulate a tmux build without -e support (issue #110)
  : > "$FAKE_TMUX_STATE/reject-capture-e"
}

fake_tmux_install_stub() { # <bindir> -- write a PATH-executable tmux shim backed by this file
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/tmux" <<EOF
#!/usr/bin/env bash
export FAKE_TMUX_STATE="$FAKE_TMUX_STATE"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fake-tmux.bash"
tmux "\$@"
EOF
  chmod +x "$bindir/tmux"
}

# --- internal resolution helpers ---------------------------------------------------

# Resolve a session name by tmux's real rule: an EXACT match wins outright;
# otherwise an UNAMBIGUOUS PREFIX match (exactly one candidate) is used.
# Prints the canonical (exact, on-disk) session name and returns 0, or
# returns 1 with nothing printed if there is no match or the prefix is
# ambiguous (confirmed against real tmux 3.4 -- see issue #96).
_fake_tmux_resolve_session() {
  local want="$1" dir="$FAKE_TMUX_STATE/sessions"
  [ -e "$dir/$want" ] && { printf '%s\n' "$want"; return 0; }
  local match="" name
  for name in "$dir"/*/; do
    [ -e "$name" ] || continue
    name="${name%/}"; name="${name##*/}"
    case "$name" in
      "$want"*)
        [ -n "$match" ] && return 1   # ambiguous prefix
        match="$name"
        ;;
    esac
  done
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

# Resolve a window within an already-resolved session by the same exact-then-
# unambiguous-prefix rule, matching on NAME; a bare numeric window part
# matches by INDEX exactly (real tmux allows both). Prints "<index>:<name>".
_fake_tmux_resolve_window() {
  local sess="$1" want="$2"
  local dir="$FAKE_TMUX_STATE/sessions/$sess/windows"
  local entry idx name match=""
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    entry="${entry##*/}"
    idx="${entry%%:*}"; name="${entry#*:}"
    if [ "$name" = "$want" ] || [ "$idx" = "$want" ]; then
      printf '%s\n' "$entry"; return 0
    fi
    case "$name" in
      "$want"*)
        [ -n "$match" ] && return 1
        match="$entry"
        ;;
    esac
  done
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

# Split "session:window" (window part optional) into globals _S/_W.
_fake_tmux_split_target() {
  _S="${1%%:*}"
  case "$1" in
    *:*) _W="${1#*:}" ;;
    *) _W="" ;;
  esac
}

# Reject any arg that looks like a flag and isn't in the given allowlist
# (space-separated). Real tmux rejects unknown options; a fake that silently
# ignores them can't express "flag unsupported" as a test scenario -- see
# issue #110. Consumes flag arguments; leaves non-flag args in $_FAKE_TMUX_ARGS.
_fake_tmux_check_flags() {
  local allowed=" $1 "; shift
  _FAKE_TMUX_ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      -*)
        case "$allowed" in
          *" $a "*) ;;
          *) printf 'fake-tmux: unknown option %s\n' "$a" >&2; return 1 ;;
        esac
        ;;
    esac
    _FAKE_TMUX_ARGS+=("$a")
  done
  return 0
}

# --- the tmux entrypoint -------------------------------------------------------

tmux() {
  local sub="${1:-}"
  [ -n "$sub" ] && shift

  local override="fake_tmux_override_${sub//-/_}"
  if declare -F "$override" >/dev/null 2>&1; then
    "$override" "$@"
    return $?
  fi

  case "$sub" in
    has-session) _fake_tmux_has_session "$@" ;;
    list-sessions) _fake_tmux_list_sessions "$@" ;;
    list-windows) _fake_tmux_list_windows "$@" ;;
    display-message) _fake_tmux_display_message "$@" ;;
    new-session) _fake_tmux_new_session "$@" ;;
    new-window) _fake_tmux_new_window "$@" ;;
    kill-window) _fake_tmux_kill_window "$@" ;;
    kill-session) _fake_tmux_kill_session "$@" ;;
    send-keys) _fake_tmux_send_keys "$@" ;;
    paste-buffer) _fake_tmux_paste_buffer "$@" ;;
    load-buffer) _fake_tmux_load_buffer "$@" ;;
    show-buffer) _fake_tmux_show_buffer "$@" ;;
    capture-pane) _fake_tmux_capture_pane "$@" ;;
    set-option) _fake_tmux_set_option "$@" ;;
    *)
      printf 'fake-tmux: unsupported subcommand: %s\n' "$sub" >&2
      return 1
      ;;
  esac
}

_fake_tmux_has_session() {
  _fake_tmux_check_flags "-t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _fake_tmux_split_target "$target"
  _fake_tmux_resolve_session "$_S" >/dev/null
}

_fake_tmux_list_sessions() {
  _fake_tmux_check_flags "-F" "$@" || return 1
  local dir="$FAKE_TMUX_STATE/sessions" name
  for name in "$dir"/*/; do
    [ -e "$name" ] || continue
    name="${name%/}"; printf '%s\n' "${name##*/}"
  done
}

_fake_tmux_list_windows() {
  _fake_tmux_check_flags "-t -F" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target="" fmt="#{window_name}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      -F) fmt="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  local entry idx name
  for entry in "$FAKE_TMUX_STATE/sessions/$sess/windows"/*; do
    [ -e "$entry" ] || continue
    entry="${entry##*/}"
    idx="${entry%%:*}"; name="${entry#*:}"
    case "$fmt" in
      '#{window_name}') printf '%s\n' "$name" ;;
      '#{window_index}') printf '%s\n' "$idx" ;;
      '#S:#W') printf '%s:%s\n' "$sess" "$name" ;;
      *) printf '%s\n' "$name" ;;
    esac
  done
}

_fake_tmux_display_message() {
  _fake_tmux_check_flags "-p -t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target="" fmt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      -p) shift ;;
      *) fmt="$1"; shift ;;
    esac
  done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  local win=""
  if [ -n "$_W" ]; then
    win="$(_fake_tmux_resolve_window "$sess" "$_W")" || return 1
    win="${win#*:}"
  fi
  case "$fmt" in
    '#{session_name}') printf '%s\n' "$sess" ;;
    '#{window_name}') printf '%s\n' "$win" ;;
    *) printf '%s\n' "$fmt" ;;
  esac
}

_fake_tmux_new_session() {
  _fake_tmux_check_flags "-d -s -n -c" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local name="" win="orchestrator"
  while [ $# -gt 0 ]; do
    case "$1" in
      -s) name="$2"; shift 2 ;;
      -n) win="$2"; shift 2 ;;
      -d|-c) shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [ -e "$FAKE_TMUX_STATE/sessions/$name" ] && { echo "fake-tmux: duplicate session: $name" >&2; return 1; }
  fake_tmux_add_session "$name" "$win"
}

_fake_tmux_new_window() {
  _fake_tmux_check_flags "-a -t -n -c" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target="" win=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      -n) win="$2"; shift 2 ;;
      -a|-c) shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  fake_tmux_add_window "$sess" "$win"
}

_fake_tmux_kill_window() {
  _fake_tmux_check_flags "-t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target=""
  while [ $# -gt 0 ]; do case "$1" in -t) target="$2"; shift 2 ;; *) shift ;; esac; done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  local entry; entry="$(_fake_tmux_resolve_window "$sess" "$_W")" || return 1
  rm -f "$FAKE_TMUX_STATE/sessions/$sess/windows/$entry" "$FAKE_TMUX_STATE/sessions/$sess/panes/${entry#*:}"
}

_fake_tmux_kill_session() {
  _fake_tmux_check_flags "-t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target=""
  while [ $# -gt 0 ]; do case "$1" in -t) target="$2"; shift 2 ;; *) shift ;; esac; done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  rm -rf "${FAKE_TMUX_STATE:?}/sessions/${sess:?}"
}

_fake_tmux_send_keys() {
  _fake_tmux_check_flags "-t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target="" keys=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      *) keys+=("$1"); shift ;;
    esac
  done
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  _fake_tmux_resolve_window "$sess" "$_W" >/dev/null || return 1
  printf 'send-keys %s\n' "${keys[*]}" >> "$FAKE_TMUX_STATE/sessions/$sess/sendkeys.log"
}

_fake_tmux_load_buffer() {
  _fake_tmux_check_flags "-b" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -b) name="$2"; shift 2 ;;
      -) shift ;;
      *) shift ;;
    esac
  done
  cat > "$FAKE_TMUX_STATE/buffers/$name"
}

_fake_tmux_show_buffer() {
  _fake_tmux_check_flags "-b" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local name=""
  while [ $# -gt 0 ]; do case "$1" in -b) name="$2"; shift 2 ;; *) shift ;; esac; done
  [ -e "$FAKE_TMUX_STATE/buffers/$name" ] || return 1
  cat "$FAKE_TMUX_STATE/buffers/$name"
}

_fake_tmux_paste_buffer() {
  _fake_tmux_check_flags "-p -d -b -t" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local name="" target="" del=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -b) name="$2"; shift 2 ;;
      -t) target="$2"; shift 2 ;;
      -d) del=1; shift ;;
      -p) shift ;;
      *) shift ;;
    esac
  done
  [ -e "$FAKE_TMUX_STATE/buffers/$name" ] || return 1
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  _fake_tmux_resolve_window "$sess" "$_W" >/dev/null || return 1
  cat "$FAKE_TMUX_STATE/buffers/$name" >> "$FAKE_TMUX_STATE/sessions/$sess/sendkeys.log"
  [ "$del" -eq 1 ] && rm -f "$FAKE_TMUX_STATE/buffers/$name"
  return 0
}

_fake_tmux_capture_pane() {
  _fake_tmux_check_flags "-t -p -e" "$@" || return 1
  set -- "${_FAKE_TMUX_ARGS[@]}"
  local target="" want_e=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -t) target="$2"; shift 2 ;;
      -e) want_e=1; shift ;;
      -p) shift ;;
      *) shift ;;
    esac
  done
  if [ "$want_e" -eq 1 ] && [ -e "$FAKE_TMUX_STATE/reject-capture-e" ]; then
    printf 'fake-tmux: unknown option -e\n' >&2
    return 1
  fi
  _fake_tmux_split_target "$target"
  local sess; sess="$(_fake_tmux_resolve_session "$_S")" || return 1
  local win; win="$(_fake_tmux_resolve_window "$sess" "$_W")" || return 1
  win="${win#*:}"
  local content=""
  [ -e "$FAKE_TMUX_STATE/sessions/$sess/panes/$win" ] && content="$(cat "$FAKE_TMUX_STATE/sessions/$sess/panes/$win")"
  if [ "$want_e" -eq 1 ]; then
    printf '\033[0m%s\033[0m\n' "$content"
  else
    printf '%s\n' "$content"
  fi
}

_fake_tmux_set_option() {
  _fake_tmux_check_flags "-t -w -g" "$@" || return 1
  return 0
}
