#!/usr/bin/env bats
# Issue #178 (#152 direction 2): heartbeat root_dirty_tick flags Bash-made writes
# into the target repo's main checkout (which the PreToolUse hook cannot see).
# Hermetic: scratch git repo, ORCH_ROOT in the bats tmp dir, no tmux, no claude.

ORCH_DIR_SRC="$BATS_TEST_DIRNAME/../_orch"

setup() {
  R="$BATS_TEST_TMPDIR/r"; mkdir -p "$R"
  export ORCH_ROOT="$R/toolkit" PROJ="$R/proj"
  mkdir -p "$ORCH_ROOT/_orch"
  git init -q -b main "$PROJ"
  git -C "$PROJ" config user.email t@example.com
  git -C "$PROJ" config user.name t
  mkdir -p "$PROJ/_orch"
  echo c > "$PROJ/_orch/config.json"; echo x > "$PROJ/f.sh"
  git -C "$PROJ" add -A; git -C "$PROJ" commit -q -m init
  echo '{}' > "$ORCH_ROOT/_orch/config.json"
  # shellcheck disable=SC1091
  source "$ORCH_DIR_SRC/heartbeat.sh"
  mkdir -p "$WORKERS_DIR" "$STATE_DIR"
  echo dirty >> "$PROJ/_orch/config.json"   # operator's own uncommitted edit
  # Hermetic tmux: session $SESSION_NAME exists; its windows are $STUB_WINS.
  tb="$BATS_TEST_TMPDIR/tmuxbin"; mkdir -p "$tb"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in list-sessions) [ -n \"$STUB_NOSESS\" ] || echo \"$SESSION_NAME\";; list-windows) [ -z \"$STUB_NOSESS$STUB_LWFAIL\" ] || exit 1; printf "%%s\\n" $STUB_WINS;; esac\nexit 0\n' > "$tb/tmux"
  chmod +x "$tb/tmux"; PATH="$tb:$PATH"; export STUB_WINS=""
}

worker() { # <id> <mode> [repo]  (also opens its tmux window)
  STUB_WINS="$STUB_WINS $1"
  jq -n --arg id "$1" --arg m "$2" --arg r "${3:-$PROJ}" \
    '{id:$id,status:"working",mode:$m,target_repo:$r}' > "$WORKERS_DIR/$1.json"
}
baseline() { root_baseline_write "${2:-$PROJ}" "$1"; }
nlines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
events() { nlines "$STATE_DIR/events.jsonl"; }
inbox() { nlines "$INBOX"; }

@test "tick reports new tracked+untracked dirt once, not baseline, re-alerts after clear" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"; echo t > "$PROJ/new.bats"
  root_dirty_tick
  [ "$(events)" -eq 1 ]; [ "$(inbox)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [ "$(jq -r .event <<<"$ev")" = root-dirty ]
  [[ "$ev" == *f.sh* ]]; [[ "$ev" == *new.bats* ]]; [[ "$ev" != *config.json* ]]
  [[ "$ev" == *w1* ]]
  root_dirty_tick
  [ "$(events)" -eq 1 ]; [ "$(inbox)" -eq 1 ]
  git -C "$PROJ" checkout -q f.sh
  root_dirty_tick; [ "$(events)" -eq 1 ]
  echo z >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 2 ]; [ "$(inbox)" -eq 2 ]
}

@test "no event when only the baseline entry is present" {
  worker w1 worktree; baseline w1
  root_dirty_tick
  [ "$(events)" -eq 0 ]; [ "$(inbox)" -eq 0 ]
  # positive control: the empty result came from a real check, not a skipped repo
  [ -f "$STATE_DIR/root-dirty/$(_orch_session_hash "$(_phys_dir "$PROJ")")" ]
}

@test "no event with zero live workers" {
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "no event for a no-worktree worker even when the root is dirtied" {
  worker w1 no-worktree; baseline w1   # baseline: excluded by mode, not by the no-baseline skip
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "done workers whose window is gone do not count as live" {
  worker w1 worktree; baseline w1
  jq '.status="done"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  STUB_WINS="orch other"
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "a done worker whose window is alive (follow-up turn) still counts as live" {
  worker w1 worktree; baseline w1
  jq '.status="done"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  STUB_WINS="orch w1"
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" == *w1* ]]
}

@test "zero worktree-mode workers: tick runs no git" {
  fb="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fb"
  printf '#!/usr/bin/env bash\necho x >> "%s/git.calls"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$fb/git"
  chmod +x "$fb/git"
  worker w1 no-worktree; baseline w1   # real git, before the fake goes on PATH
  PATH="$fb:$PATH" root_dirty_tick
  [ ! -e "$BATS_TEST_TMPDIR/git.calls" ]
}

@test "two worktree workers on one repo run git once" {
  worker w1 worktree; worker w2 worktree; baseline w1; baseline w2
  fb="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fb"
  real="$(command -v git)"
  printf '#!/usr/bin/env bash\necho x >> "%s/git.calls"\nexec %s "$@"\n' "$BATS_TEST_TMPDIR" "$real" > "$fb/git"
  chmod +x "$fb/git"
  PATH="$fb:$PATH" root_dirty_tick
  [ "$(nlines "$BATS_TEST_TMPDIR/git.calls")" -eq 1 ]
}

@test "spawn writes a baseline for worktree mode (target repo), none for --no-worktree; clean removes it" {
  stub="$BATS_TEST_TMPDIR/bin"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in list-sessions) echo nosuch178;; capture-pane) echo "> ready for shortcuts";; esac\nexit 0\n' > "$stub/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"
  chmod +x "$stub/tmux" "$stub/claude"
  export SESSION_NAME=nosuch178
  echo '{"thresholds":{"max_workers":4,"min_free_mb":0,"est_worker_mb":0},"budget":{"enabled":false,"max_usd":5.0,"est_usd_per_worker":0.5}}' > "$ORCH_ROOT/_orch/config.json"
  unset ORCH_REPO_EXPLICIT PROJECT_ROOT ORCH_TARGET_REPO
  sp() { env PATH="$stub:$PATH" PROJECT_ROOT="$PROJ" ORCH_ALLOW_UNRELATED_REPO=1 "$ORCH_DIR_SRC/spawn.sh" "$@"; }
  run sp w1 sonnet task; [ "$status" -eq 0 ]
  f="$(root_baseline_file "$PROJ" w1)"
  [ -f "$f" ]; grep -q '_orch/config.json' "$f"
  run sp w2 sonnet task --no-worktree; [ "$status" -eq 0 ]
  [ ! -e "$(root_baseline_file "$PROJ" w2)" ]
  run env PATH="$stub:$PATH" PROJECT_ROOT="$PROJ" "$ORCH_DIR_SRC/clean.sh" w1
  [ ! -e "$f" ]
}

@test "baseline key includes the repo: same id in another repo is a separate file" {
  other="$R/other"; git init -q -b main "$other"
  [ "$(root_baseline_file "$PROJ" w1)" != "$(root_baseline_file "$other" w1)" ]
}

@test "operator edit between two worker spawns does not alert; union of baselines governs" {
  worker w1 worktree; baseline w1
  echo op >> "$PROJ/f.sh"          # operator edit between spawns
  worker w2 worktree; baseline w2
  root_dirty_tick
  [ "$(events)" -eq 0 ]
  echo n > "$PROJ/later.txt"       # new after both spawns
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [[ "$ev" == *later.txt* ]]; [[ "$ev" != *'"f.sh'* ]]
  [[ "$ev" == *w1* ]]; [[ "$ev" == *w2* ]]
}

@test "a worker's write before a later spawn is caught when ticked first" {
  worker w1 worktree; baseline w1
  echo w >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [[ "$ev" == *'"f.sh"'* ]]
  worker w2 worktree; baseline w2      # later spawn absorbs f.sh into its baseline
  grep -qx ' M f.sh' "$(root_baseline_file "$PROJ" w2)"
  root_dirty_tick
  [ "$(events)" -eq 1 ]                # no duplicate alert
}

@test "dead workers do not count as live" {
  worker w1 worktree; baseline w1
  jq '.status="dead"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "a failed git status keeps the reported record (no re-alert)" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  fb="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 128\n' > "$fb/git"; chmod +x "$fb/git"
  PATH="$fb:$PATH" root_dirty_tick
  [ -s "$STATE_DIR/root-dirty/$(_orch_session_hash "$(_phys_dir "$PROJ")")" ]
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "worker without a baseline file suppresses the repo (cannot tell operator from worker)" {
  worker w1 worktree
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
}

@test "operator staging a baseline entry does not alert (paths compared, not XY codes)" {
  worker w1 worktree; baseline w1
  git -C "$PROJ" add _orch/config.json
  root_dirty_tick
  [ "$(events)" -eq 0 ]
  echo y >> "$PROJ/f.sh"               # positive control: the repo IS being checked
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" != *config.json* ]]
}

@test "reported record is forgotten once no worktree worker is live" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  jq '.status="done"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  STUB_WINS=""                         # w1's window closed
  git -C "$PROJ" checkout -q f.sh
  root_dirty_tick
  worker w2 worktree; baseline w2
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 2 ]
}

@test "a non-done worker whose window is gone (needs-input, never marked dead) is not live" {
  worker w1 worktree; baseline w1
  jq '.status="needs-input"' "$WORKERS_DIR/w1.json" > "$WORKERS_DIR/t" && mv "$WORKERS_DIR/t" "$WORKERS_DIR/w1.json"
  STUB_WINS="orch other"
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 0 ]
  STUB_WINS="orch w1"                  # control: same worker with its window alerts
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "an unlistable tmux session skips the tick and keeps the reported record" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  STUB_NOSESS=1 root_dirty_tick
  [ -s "$STATE_DIR/root-dirty/$(_orch_session_hash "$(_phys_dir "$PROJ")")" ]
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "operator edit masked by a later spawn stays silent after that worker leaves" {
  worker w1 worktree; baseline w1
  echo op >> "$PROJ/f.sh"              # operator edit between spawns
  worker w2 worktree; baseline w2      # absorbed by w2's baseline
  root_dirty_tick; [ "$(events)" -eq 0 ]
  STUB_WINS=" w1"                      # w2's window closed; w1 still live
  root_dirty_tick
  [ "$(events)" -eq 0 ]
  echo n > "$PROJ/later.txt"           # positive control: repo still checked
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" != *'"f.sh'* ]]
}

@test "a clean checkout at spawn (empty baseline) still alerts on a new write" {
  git -C "$PROJ" checkout -q _orch/config.json   # undo setup's operator edit
  worker w1 worktree; baseline w1
  [ ! -s "$(root_baseline_file "$PROJ" w1)" ]    # baseline is genuinely empty
  echo y >> "$PROJ/f.sh"
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" == *'"f.sh"'* ]]
}

@test "a baseline path that clears and is re-dirtied while the worker lives re-alerts" {
  worker w1 worktree; baseline w1                 # baseline holds _orch/config.json
  git -C "$PROJ" checkout -q _orch/config.json    # operator reverts their edit
  root_dirty_tick; [ "$(events)" -eq 0 ]
  ! grep -q 'config.json' "$(root_baseline_file "$PROJ" w1)"   # dropped from baseline
  echo w >> "$PROJ/_orch/config.json"             # worker's Bash write to the same path
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" == *config.json* ]]
}

@test "a live worker's momentarily unreachable repo keeps its reported record" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  mv "$PROJ" "$PROJ.away"              # e.g. network FS unmounted
  root_dirty_tick
  mv "$PROJ.away" "$PROJ"
  [ -s "$STATE_DIR/root-dirty/$(_orch_session_hash "$(_phys_dir "$PROJ")")" ]
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "event path list is capped (it is pasted into the master pane) with the full count" {
  worker w1 worktree; baseline w1
  mkdir "$PROJ/build"; for i in $(seq 1 120); do : > "$PROJ/build/o$i"; done
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [ "$(jq '.paths|length' <<<"$ev")" -eq 50 ]
  [ "$(jq '.paths_total' <<<"$ev")" -eq 120 ]
  root_dirty_tick; [ "$(events)" -eq 1 ]   # all 120 recorded, not just the 50 shown
}

@test "toolkit state inside the target checkout (vendored, not gitignored) is never reported" {
  STATE_DIR="$PROJ/_orch/state"; WORKERS_DIR="$STATE_DIR/workers"; INBOX="$STATE_DIR/inbox.jsonl"
  mkdir -p "$WORKERS_DIR"; : > "$INBOX"
  baseline w1; worker w1 worktree      # status file lands after the baseline, as in spawn
  root_dirty_tick; root_dirty_tick     # 2nd tick: the tick's own record/events files exist
  [ "$(events)" -eq 0 ]
  echo y >> "$PROJ/f.sh"               # positive control: the repo IS being checked
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" != *_orch/state* ]]
}

@test "a listed session whose window listing fails skips the tick and keeps the record" {
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  STUB_LWFAIL=1 root_dirty_tick        # session exists; only list-windows fails
  [ -s "$STATE_DIR/root-dirty/$(_orch_session_hash "$(_phys_dir "$PROJ")")" ]
  root_dirty_tick
  [ "$(events)" -eq 1 ]
}

@test "toolkit state beside a subdirectory target is excluded too" {
  mkdir -p "$PROJ/pkg"; echo a > "$PROJ/pkg/a"
  git -C "$PROJ" add pkg; git -C "$PROJ" commit -q -m pkg
  STATE_DIR="$PROJ/_orch/state"; WORKERS_DIR="$STATE_DIR/workers"; INBOX="$STATE_DIR/inbox.jsonl"
  mkdir -p "$WORKERS_DIR"; : > "$INBOX"
  baseline w1 "$PROJ/pkg"; worker w1 worktree "$PROJ/pkg"
  root_dirty_tick; root_dirty_tick
  [ "$(events)" -eq 0 ]
  echo y >> "$PROJ/f.sh"               # positive control
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" != *_orch/state* ]]
}

@test "an unreachable repo does not keep another repo's stale record alive" {
  other="$R/other"; git init -q -b main "$other"
  git -C "$other" -c user.email=t@e -c user.name=t commit -q --allow-empty -m i
  worker w1 worktree; baseline w1
  echo y >> "$PROJ/f.sh"
  root_dirty_tick; [ "$(events)" -eq 1 ]
  worker wo worktree "$other"; baseline wo "$other"
  root_dirty_tick                       # other repo gets its own record
  STUB_WINS=" wo"                       # w1 leaves; operator reverts
  git -C "$PROJ" checkout -q f.sh
  mv "$other" "$other.away"             # the other live worker's repo is unreachable
  root_dirty_tick
  mv "$other.away" "$other"
  worker w2 worktree; baseline w2
  echo y >> "$PROJ/f.sh"                # w2 re-dirties the path w1 was reported for
  root_dirty_tick
  [ "$(events)" -eq 2 ]
}

@test "GIT_LITERAL_PATHSPECS in the env does not blind the in-repo-state check" {
  STATE_DIR="$PROJ/_orch/state"; WORKERS_DIR="$STATE_DIR/workers"; INBOX="$STATE_DIR/inbox.jsonl"
  mkdir -p "$WORKERS_DIR"; : > "$INBOX"
  baseline w1; worker w1 worktree      # pathspec form: state dir is inside the checkout
  echo y >> "$PROJ/f.sh"
  GIT_LITERAL_PATHSPECS=1 root_dirty_tick
  [ "$(events)" -eq 1 ]
  [[ "$(tail -1 "$STATE_DIR/events.jsonl")" == *'"f.sh"'* ]]
}

@test "subdirectory target: event names the checkout top the paths are relative to" {
  mkdir -p "$PROJ/pkg"; echo a > "$PROJ/pkg/a"
  git -C "$PROJ" add pkg; git -C "$PROJ" commit -q -m pkg
  worker w1 worktree "$PROJ/pkg"; baseline w1 "$PROJ/pkg"
  echo b >> "$PROJ/pkg/a"
  root_dirty_tick
  [ "$(events)" -eq 1 ]
  ev="$(tail -1 "$STATE_DIR/events.jsonl")"
  [ "$(jq -r .repo <<<"$ev")" = "$(_phys_dir "$PROJ")" ]
  [ -f "$(jq -r .repo <<<"$ev")/$(jq -r '.paths[0]' <<<"$ev")" ]
}
