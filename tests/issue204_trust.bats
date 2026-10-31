#!/usr/bin/env bats
# Issue #204: `orch spawn` into a repo Claude Code never trusted always ended
# spawn-failed on the folder-trust dialog. Fix under test: a READ-ONLY trust
# preflight in spawn.sh (refuse early, point at `orch trust`), plus
# `orch trust <repo>` (interactive) / `orch trust <repo> --yes` (throwaway
# window in the repo root, dialog accepted by arrow+Enter only after the trust
# regex confirms the dialog and the cursor row). Everything is hermetic: scratch
# CLAUDE_CONFIG_DIR + HOME, a stateful tmux stub, a claude stub; the real
# ~/.claude.json is never read or written.
#
# Keying rule (probe 2026-10-31, Claude Code 2.1.316, see issue #204): trust is
# recorded under the MAIN repo root, not the worktree; a parent dir's entry does
# not cover children.

# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/helpers/refute.bash"
SPAWN="$BATS_TEST_DIRNAME/../_orch/spawn.sh"
TRUST="$BATS_TEST_DIRNAME/../_orch/trust.sh"
LIB="$BATS_TEST_DIRNAME/../_orch/lib.sh"
FX="$BATS_TEST_DIRNAME/fixtures"

setup() {
  STUBBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  CALLS="$BATS_TEST_TMPDIR/tmux_calls.log"; : > "$CALLS"
  ST="$BATS_TEST_TMPDIR/tmuxstate"; mkdir -p "$ST"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
  CFG="$CLAUDE_CONFIG_DIR/.claude.json"

  export ORCH_ROOT="$BATS_TEST_TMPDIR/orch_root"
  export SESSION_NAME="orch"
  unset ORCH_SKIP_TRUST_CHECK ORCH_TRUST_FORCE_INTERACTIVE
  mkdir -p "$ORCH_ROOT/_orch"
  jq '{
    thresholds: { max_workers: 4, min_free_mb: 0, est_worker_mb: 0, spawn_inject_retries: 2 },
    budget: { enabled: false, max_usd: 5.0, est_usd_per_worker: 0.5 },
    tui_patterns: .tui_patterns
  }' "$BATS_TEST_DIRNAME/../_orch/config.json" > "$ORCH_ROOT/_orch/config.json"

  # A real scratch repo (physical path: macOS-style symlinked tmp dirs resolve).
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  REPO="$(cd -P "$REPO" && pwd -P)"
  export PROJECT_ROOT="$REPO"

  # Stateful tmux stub. Pane modes: dialog_no (cursor on "No, exit"),
  # dialog_yes, boot (nothing recognisable), ready, gone. Down moves the cursor
  # (unless STUB_DOWN_NOOP), Enter on dialog_yes "accepts": writes the trust key
  # into the scratch config and goes ready; Enter on dialog_no exits (gone).
  # `/exit` + Enter on a ready pane closes the window.
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
ST="$ST"
mode() { cat "\$ST/mode" 2>/dev/null || echo gone; }
case "\${1:-}" in
  list-sessions) echo orch ;;
  has-session) exit 0 ;;
  list-windows) [ "\$(mode)" = gone ] || echo "@9" ;;
  new-window)
    echo "\${STUB_START_MODE:-dialog_no}" > "\$ST/mode"
    for a in "\$@"; do [ "\$a" = "-P" ] && echo "@9"; done
    for a in "\$@"; do :; done
    exit 0 ;;
  capture-pane)
    case "\$(mode)" in
      dialog_no)  cat "$FX/trust_dialog.txt" ;;
      dialog_yes) sed -e 's/^ ❯ No, exit/   No, exit/' -e 's/^   Yes, I trust this folder/ ❯ Yes, I trust this folder/' "$FX/trust_dialog.txt" ;;
      boot)       echo "starting..." ;;
      lookalike)  printf 'Quit session?\n❯ No, exit\n' ;;
      ready)      printf '╭──────╮\n│ ❯     │\n╰──────╯\n' ;;
      *) exit 1 ;;
    esac ;;
  send-keys)
    for a in "\$@"; do
      case "\$a" in
        Down) [ -n "\${STUB_DOWN_NOOP:-}" ] || { [ "\$(mode)" = dialog_no ] && echo dialog_yes > "\$ST/mode"; } ;;
        Enter)
          case "\$(mode)" in
            dialog_yes)
              jq --arg r "\$STUB_TRUST_REPO" '.projects[\$r].hasTrustDialogAccepted = true' "\$CLAUDE_CONFIG_DIR/.claude.json" > "\$ST/cfg.new" && mv "\$ST/cfg.new" "\$CLAUDE_CONFIG_DIR/.claude.json"
              echo ready > "\$ST/mode" ;;
            dialog_no) echo gone > "\$ST/mode" ;;
            ready) [ -f "\$ST/exit_typed" ] && echo gone > "\$ST/mode" ;;
          esac ;;
        /exit) : > "\$ST/exit_typed" ;;
      esac
    done ;;
  kill-window) echo gone > "\$ST/mode" ;;
esac
exit 0
STUB
  cat > "$STUBBIN/claude" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "2.1.316 (Claude Code)" ;;
  *) [ -n "${STUB_CLAUDE_TRUSTS:-}" ] && jq --arg r "$STUB_CLAUDE_TRUSTS" '.projects[$r].hasTrustDialogAccepted = true' "$CLAUDE_CONFIG_DIR/.claude.json" > "$CLAUDE_CONFIG_DIR/.new" && mv "$CLAUDE_CONFIG_DIR/.new" "$CLAUDE_CONFIG_DIR/.claude.json" ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/sleep"
  chmod +x "$STUBBIN/tmux" "$STUBBIN/claude" "$STUBBIN/sleep"
  export STUB_TRUST_REPO="$REPO"
  REAL_GIT="$(command -v git)"
  PATH="$STUBBIN:$PATH"
}

cfg_untrusted() { printf '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}}}\n' > "$CFG"; }
cfg_trusted()   { jq -n --arg r "$REPO" '{projects:{($r):{hasTrustDialogAccepted:true}}}' > "$CFG"; }
sent_keys()     { grep -E '^send-keys' "$CALLS" || true; }

# --- 1. reader ----------------------------------------------------------------------

state_of() { bash -c 'source "$1"; repo_trust_state "$2"' _ "$LIB" "$1"; }

@test "repo_trust_state: accepted entry => trusted" {
  cfg_trusted
  [ "$(state_of "$REPO")" = trusted ]
}

@test "repo_trust_state: missing or false entry in a valid config => untrusted" {
  cfg_untrusted
  [ "$(state_of "$REPO")" = untrusted ]
  jq -n --arg r "$REPO" '{projects:{($r):{hasTrustDialogAccepted:false}}}' > "$CFG"
  [ "$(state_of "$REPO")" = untrusted ]
}

@test "repo_trust_state: absent/empty/invalid/odd config => unknown" {
  [ "$(state_of "$REPO")" = unknown ]
  : > "$CFG"; [ "$(state_of "$REPO")" = unknown ]
  echo '{not json' > "$CFG"; [ "$(state_of "$REPO")" = unknown ]
  echo '{"projects":[1]}' > "$CFG"; [ "$(state_of "$REPO")" = unknown ]
  echo '{}' > "$CFG"; [ "$(state_of "$REPO")" = unknown ]
}

@test "repo_trust_state: CLAUDE_CONFIG_DIR wins over HOME; HOME/.claude.json used when unset" {
  cfg_trusted
  echo '{"projects":{}}' > "$HOME/.claude.json"
  [ "$(state_of "$REPO")" = trusted ]
  unset CLAUDE_CONFIG_DIR
  [ "$(state_of "$REPO")" = untrusted ]
}

@test "repo_trust_state: a worktree resolves to the main repo root (keying rule, #204 probe)" {
  git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/wt2" -b b2
  cfg_trusted
  [ "$(state_of "$BATS_TEST_TMPDIR/wt2")" = trusted ]
  # an entry for the worktree path ONLY does not make the repo trusted
  jq -n --arg r "$(cd -P "$BATS_TEST_TMPDIR/wt2" && pwd -P)" '{projects:{($r):{hasTrustDialogAccepted:true}}}' > "$CFG"
  [ "$(state_of "$REPO")" = untrusted ]
  [ "$(state_of "$BATS_TEST_TMPDIR/wt2")" = untrusted ]
}

@test "repo_trust_state: a trusted parent dir does not cover a child repo" {
  jq -n --arg r "$(dirname "$REPO")" '{projects:{($r):{hasTrustDialogAccepted:true}}}' > "$CFG"
  [ "$(state_of "$REPO")" = untrusted ]
}

@test "repo_trust_state never writes the config" {
  cfg_untrusted; before="$(cksum < "$CFG")"
  state_of "$REPO" >/dev/null
  [ "$(cksum < "$CFG")" = "$before" ]
}

# --- 2/3/4. spawn preflight ---------------------------------------------------------

@test "spawn into an untrusted repo is refused before anything is created" {
  cfg_untrusted
  run "$SPAWN" w1 sonnet "do it" --allow "Bash(git status)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$REPO"* ]]
  [[ "$output" == *"orch trust"* ]]
  refute_grep '^(new-window|send-keys|load-buffer|paste-buffer)' "$CALLS"
  [ ! -e "$ORCH_ROOT/_orch/state/workers/w1.json" ]
  refute_grep '.' "$ORCH_ROOT/_orch/state/events.jsonl"
  refute_grep '.' "$ORCH_ROOT/_orch/state/inbox.jsonl"
  [ -z "$(ls -d "$BATS_TEST_TMPDIR"/wt* 2>/dev/null)" ]
  [ "$(git -C "$REPO" worktree list | wc -l)" -eq 1 ]
}

@test "spawn into a trusted repo is not refused" {
  cfg_trusted
  echo ready > "$ST/mode"
  run "$SPAWN" w1 sonnet "do it" --no-worktree
  [[ "$output" != *"orch trust"* ]]
  grep -q '^new-window' "$CALLS"
}

@test "unknown config falls through to the dialog guard: no key sent, spawn-failed (#133 behaviour)" {
  echo '{not json' > "$CFG"
  echo dialog_no > "$ST/mode"
  cat > "$STUBBIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
case "\${1:-}" in
  list-sessions) echo orch ;;
  capture-pane) cat "$FX/trust_dialog.txt" ;;
  show-buffer) exit 1 ;;
esac
exit 0
STUB
  run "$SPAWN" w1 sonnet "do it" --no-worktree
  [[ "$output" == *"spawn-failed w1"* ]]
  [ "$(jq -r .status "$ORCH_ROOT/_orch/state/workers/w1.json")" = spawn-failed ]
  refute_grep '^send-keys -t [^ ]+ (Enter|Down)$' "$CALLS"
  refute_grep 'paste-buffer' "$CALLS"
}

@test "ORCH_SKIP_TRUST_CHECK=1 bypasses the preflight for an untrusted config" {
  cfg_untrusted
  echo ready > "$ST/mode"
  ORCH_SKIP_TRUST_CHECK=1 run "$SPAWN" w1 sonnet "do it" --no-worktree
  [[ "$output" != *"orch trust"* ]]
  grep -q '^new-window' "$CALLS"
}

# --- 6. orch trust ------------------------------------------------------------------

@test "trust without a TTY prints the one-liner, exits 1, touches nothing" {
  cfg_untrusted; before="$(cksum < "$CFG")"
  run "$TRUST" "$REPO" < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"cd $REPO && claude"* ]]
  [ "$(cksum < "$CFG")" = "$before" ]
  [ ! -s "$CALLS" ]
  [ ! -e "$HOME/.claude.json" ]
}

@test "trust on an already-trusted repo says so, exits 0, opens no window" {
  cfg_trusted
  run "$TRUST" "$REPO" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already trusted"* ]]
  refute_grep '^new-window' "$CALLS"
}

@test "trust interactive (forced) reports trusted once claude recorded it" {
  cfg_untrusted
  STUB_CLAUDE_TRUSTS="$REPO" ORCH_TRUST_FORCE_INTERACTIVE=1 run "$TRUST" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trusted"* ]]
}

@test "trust interactive (forced) exits 1 when the dialog was not accepted" {
  cfg_untrusted
  ORCH_TRUST_FORCE_INTERACTIVE=1 run "$TRUST" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"still not trusted"* ]]
}

@test "trust --yes accepts via Down+Enter, closes the window, audits the event" {
  cfg_untrusted
  run "$TRUST" "$REPO" --yes
  [ "$status" -eq 0 ]
  [ "$(state_of "$REPO")" = trusted ]
  grep -qE '^new-window .*-c '"$REPO" "$CALLS"
  keys="$(sent_keys)"
  # Down strictly before Enter, nothing else dangerous
  [ "$(echo "$keys" | grep -n 'Down' | head -1 | cut -d: -f1)" -lt "$(echo "$keys" | grep -n 'Enter' | head -1 | cut -d: -f1)" ]
  [ "$(cat "$ST/mode")" = gone ]
  ev="$ORCH_ROOT/_orch/state/events.jsonl"
  [ "$(jq -r 'select(.event=="repo-trusted") | .repo' "$ev")" = "$REPO" ]
  [ -n "$(jq -r 'select(.event=="repo-trusted") | .who' "$ev")" ]
  [ "$(jq -r 'select(.event=="repo-trusted") | .claude_version' "$ev")" = "2.1.316" ]
  [ -n "$(jq -r 'select(.event=="repo-trusted") | .ts' "$ev")" ]
}

@test "trust --yes sends NO key when the dialog never appears, kills only its window" {
  cfg_untrusted
  STUB_START_MODE=boot ORCH_TRUST_WAIT=3 run "$TRUST" "$REPO" --yes
  [ "$status" -ne 0 ]
  [ -z "$(sent_keys)" ]
  grep -q '^kill-window' "$CALLS"
  [ "$(state_of "$REPO")" = untrusted ]
  refute_grep 'repo-trusted' "$ORCH_ROOT/_orch/state/events.jsonl"
}

@test "trust --yes sends NO key at a lookalike pane that is not the trust dialog (a lone \"No, exit\" row)" {
  cfg_untrusted
  STUB_START_MODE=lookalike ORCH_TRUST_WAIT=3 run "$TRUST" "$REPO" --yes
  [ "$status" -ne 0 ]
  [ -z "$(sent_keys)" ]
  [ "$(state_of "$REPO")" = untrusted ]
}

@test "trust --yes sends NO Enter when the cursor is not on 'Yes, I trust this folder'" {
  cfg_untrusted
  STUB_DOWN_NOOP=1 ORCH_TRUST_WAIT=3 run "$TRUST" "$REPO" --yes
  [ "$status" -ne 0 ]
  [ -z "$(sent_keys | grep 'Enter' || true)" ]
  grep -q '^kill-window' "$CALLS"
  [ "$(state_of "$REPO")" = untrusted ]
}

@test "trust --yes kills only the window it created (exact target)" {
  cfg_untrusted
  STUB_START_MODE=boot ORCH_TRUST_WAIT=2 run "$TRUST" "$REPO" --yes
  kills="$(grep '^kill-window' "$CALLS")"
  [ "$(echo "$kills" | wc -l)" -eq 1 ]
  [[ "$kills" == *"@9"* ]]
}

# --- cli ----------------------------------------------------------------------------

@test "orch trust is dispatched by the CLI and listed in help" {
  cfg_untrusted
  run "$BATS_TEST_DIRNAME/../orch" trust "$REPO" < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"cd $REPO && claude"* ]]
  run "$BATS_TEST_DIRNAME/../orch" help
  [[ "$output" == *"orch trust"* ]]
  [[ "$output" == *"ORCH_SKIP_TRUST_CHECK"* ]]
}
