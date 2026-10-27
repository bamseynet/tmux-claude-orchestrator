#!/usr/bin/env bats
# Issue #202: install.sh / `orch update` three-way-merge new shipped config.json
# defaults into an existing install's config.json (base = _orch/config.shipped.json
# snapshot), force-update the managed dialog regexes (with backup) unless pinned.
# Hermetic: scratch target + scratch source copies; never launches the real loop.

INSTALL="$BATS_TEST_DIRNAME/../install.sh"
REPO="$BATS_TEST_DIRNAME/.."
STALE_PERM='Do you want to proceed\?'
STALE_TRUST='trust this folder|created or one you trust'

setup() {
  unset ORCH_ROOT SESSION_NAME
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET/.git"
}

# mk_src: scratch copy of the toolkit whose shipped config.json we can edit.
mk_src() {
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC"
  cp -R "$REPO/_orch" "$REPO/tmux" "$REPO/scripts" "$SRC/"
  cp "$REPO/orch" "$REPO/install.sh" "$REPO/VERSION" "$SRC/"
  rm -rf "$SRC/_orch/state"
}

# edit <file> <jq filter> [jq args...]
edit() {
  local f="$1" flt="$2"; shift 2
  jq "$@" "$flt" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

cfg() { jq -r "$1" "$TARGET/_orch/config.json"; }

@test "bootstrap: a 0.2.0-shaped config gains every shipped leaf key" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  cp "$BATS_TEST_DIRNAME/fixtures/config-0.2.0.json" "$TARGET/_orch/config.json"
  rm -f "$TARGET/_orch/config.shipped.json"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  # every leaf path of the shipped config exists in the merged one
  run jq -n --slurpfile o "$TARGET/_orch/config.json" --slurpfile t "$REPO/_orch/config.json" \
    '[$t[0] | paths(type != "object" and type != "array") | select(. as $p | ($o[0] | getpath($p)) == null and ($t[0] | getpath($p)) != null)] | length'
  [ "$output" = "0" ]
  [ -f "$TARGET/_orch/config.shipped.json" ]
}

@test "operator tuning survives; budget.enabled=false kept and listed '=' only because the shipped default differs" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  edit "$TARGET/_orch/config.json" '.thresholds.max_workers = 99 | .budget.enabled = false'
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(cfg .thresholds.max_workers)" = "99" ]
  [ "$(cfg .budget.enabled)" = "false" ]
  # shipped defaults did not move -> silent (snapshot is the base)
  [[ "$output" == *"up to date"* ]]
  [[ "$output" != *"budget.enabled"* ]]
}

@test "snapshot: untouched key follows a moved default (~); edited key is kept (=) and listed only when the default moved" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  [ -f "$TARGET/_orch/config.shipped.json" ]
  edit "$TARGET/_orch/config.json" '.thresholds.max_workers = 99 | .thresholds.min_free_mb = 1'
  # ship: stale-untouched key moves, edited+moved key moves, edited-unmoved stays
  edit "$SRC/_orch/config.json" '.thresholds.est_worker_mb = 777 | .thresholds.min_free_mb = 2048'
  run "$SRC/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(cfg .thresholds.est_worker_mb)" = "777" ]
  [[ "$output" == *"~ thresholds.est_worker_mb"* ]]
  [ "$(cfg .thresholds.min_free_mb)" = "1" ]
  [[ "$output" == *"= thresholds.min_free_mb"* ]]
  [ "$(cfg .thresholds.max_workers)" = "99" ]
  [[ "$output" != *"thresholds.max_workers"* ]]
}

@test "snapshot: a key new in the shipped config is added (+)" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  edit "$SRC/_orch/config.json" '.thresholds.brand_new = 5'
  run "$SRC/install.sh" "$TARGET"
  [[ "$output" == *"+ thresholds.brand_new"* ]]
  [ "$(cfg .thresholds.brand_new)" = "5" ]
  [[ "$output" == *"1 added"* ]]
}

@test "snapshot: a type conflict (operator scalar where shipped is an object) is kept and reported" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  edit "$TARGET/_orch/config.json" '.merge = "off"'
  edit "$SRC/_orch/config.json" '.merge.auto = true'
  run "$SRC/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(cfg .merge)" = "off" ]
  [[ "$output" == *"= merge"* ]]
}

@test "bootstrap: a value in the legacy table is updated, an unlisted value is kept" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  rm -f "$TARGET/_orch/config.shipped.json"
  # watchdog.rate_limit_regex has historical shipped values; take an older one.
  old="$(jq -r --slurpfile c "$REPO/_orch/config.json" \
    '.legacy["watchdog.rate_limit_regex"] | map(select(. != $c[0].watchdog.rate_limit_regex)) | .[0]' \
    "$REPO/scripts/config-legacy-defaults.json")"
  [ -n "$old" ] && [ "$old" != "null" ]
  edit "$TARGET/_orch/config.json" '.watchdog.rate_limit_regex = $v | .thresholds.max_workers = 99' --arg v "$old"
  run "$SRC/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(cfg .watchdog.rate_limit_regex)" = "$(jq -r .watchdog.rate_limit_regex "$REPO/_orch/config.json")" ]
  [ "$(cfg .thresholds.max_workers)" = "99" ]
  [ -f "$TARGET/_orch/config.shipped.json" ]
}

@test "managed: unrecognised operator dialog regexes are overwritten, backed up, and flagged MANAGED" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  echo "0.2.0" > "$TARGET/.orch-version"
  edit "$TARGET/_orch/config.json" \
    '.tui_patterns.permission_dialog_regex = $p | .tui_patterns.trust_dialog_regex = $t | .budget.enabled = false' \
    --arg p "$STALE_PERM" --arg t "$STALE_TRUST"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MANAGED"* ]]
  [ "$(cfg .tui_patterns.permission_dialog_regex)" = "$(jq -r .tui_patterns.permission_dialog_regex "$REPO/_orch/config.json")" ]
  [ "$(cfg .tui_patterns.trust_dialog_regex)" = "$(jq -r .tui_patterns.trust_dialog_regex "$REPO/_orch/config.json")" ]
  [ "$(cfg .budget.enabled)" = "false" ]
  bak="$TARGET/_orch/config.json.bak.0.2.0"
  [ -f "$bak" ]
  [ "$(jq -r .tui_patterns.permission_dialog_regex "$bak")" = "$STALE_PERM" ]
  [ "$(jq -r .tui_patterns.trust_dialog_regex "$bak")" = "$STALE_TRUST" ]
  [[ "$output" == *"config.json.bak.0.2.0"* ]]
}

@test "managed: an existing backup is never clobbered by a later overwrite at the same prev_version" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  echo "0.2.0" > "$TARGET/.orch-version"
  edit "$TARGET/_orch/config.json" '.tui_patterns.permission_dialog_regex = "FIRST"'
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  echo "0.2.0" > "$TARGET/.orch-version"
  edit "$TARGET/_orch/config.json" '.tui_patterns.permission_dialog_regex = "SECOND"'
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  [ "$(jq -r .tui_patterns.permission_dialog_regex "$TARGET/_orch/config.json.bak.0.2.0")" = "FIRST" ]
  [ "$(jq -r .tui_patterns.permission_dialog_regex "$TARGET/_orch/config.json.bak.0.2.0.1")" = "SECOND" ]
}

@test "config.json mode and symlink survive a merge; empty-object shipped default is added" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  chmod 600 "$TARGET/_orch/config.json"
  edit "$SRC/_orch/config.json" '.newsect = {}'
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  [ "$(cfg '.newsect | type')" = "object" ]
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]   # {} default already present: no false type conflict
  [ "$(stat -c %a "$TARGET/_orch/config.json" 2>/dev/null || stat -f %Lp "$TARGET/_orch/config.json")" = "600" ]
  mv "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$TARGET/_orch/config.json"
  edit "$SRC/_orch/config.json" '.another = 1'
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  [ -L "$TARGET/_orch/config.json" ]
  [ "$(jq -r .another "$BATS_TEST_TMPDIR/real.json")" = "1" ]
}

@test "managed: a key listed in pinned_keys is kept, reported PINNED every run, and not backed up" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  edit "$TARGET/_orch/config.json" \
    '.tui_patterns.trust_dialog_regex = $t | .pinned_keys = ["tui_patterns.trust_dialog_regex"]' --arg t "$STALE_TRUST"
  for _ in 1 2; do
    run "$INSTALL" "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PINNED"* ]]
    [[ "$output" == *"tui_patterns.trust_dialog_regex"* ]]
    [ "$(cfg .tui_patterns.trust_dialog_regex)" = "$STALE_TRUST" ]
  done
  ls "$TARGET/_orch"/config.json.bak.* 2>/dev/null && return 1
  return 0
}

@test "managed: stale permission regex fixed after update (#198 recognises the file-edit dialog)" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  edit "$TARGET/_orch/config.json" '.tui_patterns.permission_dialog_regex = $p' --arg p "$STALE_PERM"
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  run env -i HOME="$HOME" PATH="$PATH" ORCH_ROOT="$TARGET" bash -c '
    source "$ORCH_ROOT/_orch/lib.sh"
    printf " Do you want to make this edit to foo.sh?\n❯ 1. Yes\n  2. No\n" > "$ORCH_ROOT/screen.txt"
    _dialog_in "$(cat "$ORCH_ROOT/screen.txt")" "$TUI_PERMISSION_DIALOG_REGEX" "$TUI_PERMISSION_CHOICE_REGEX" && echo RECOGNISED
    echo "RX=$TUI_PERMISSION_DIALOG_REGEX"'
  [[ "$output" == *"RECOGNISED"* ]]
  [[ "$output" != *'RX=Do you want to proceed\?'* ]]
}

@test "no-drift: a second run prints only 'up to date', config.json byte-identical" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  edit "$TARGET/_orch/config.json" '.thresholds.max_workers = 99'
  "$INSTALL" "$TARGET" >/dev/null
  cp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config.json: up to date"* ]]
  [[ "$output" != *"    +"* && "$output" != *"    ~"* && "$output" != *"    !"* && "$output" != *"    ="* ]]
  cmp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "invalid-JSON config.json: install exits 0, file untouched, no snapshot, loud message" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  rm -f "$TARGET/_orch/config.shipped.json"
  echo '{ not json' > "$TARGET/_orch/config.json"
  cp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config.json is not valid JSON; defaults NOT applied"* ]]
  cmp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  [ ! -e "$TARGET/_orch/config.shipped.json" ]
}

@test "zero-byte config.json: install exits 0, file untouched, no snapshot, loud message" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  rm -f "$TARGET/_orch/config.shipped.json"
  : > "$TARGET/_orch/config.json"
  run "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defaults NOT applied"* ]]
  [ ! -s "$TARGET/_orch/config.json" ]
  [ ! -e "$TARGET/_orch/config.shipped.json" ]
}

@test "jq missing from PATH: install exits 0, config.json untouched, no snapshot, loud message" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  rm -f "$TARGET/_orch/config.shipped.json"
  edit "$TARGET/_orch/config.json" '.thresholds.max_workers = 99'
  cp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  # PATH with every tool install.sh needs symlinked in, except jq
  nojq="$BATS_TEST_TMPDIR/nojq"; mkdir -p "$nojq"
  for t in bash cat cp mv rm mkdir mktemp find dirname chmod touch grep tmux claude perl git; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$nojq/$t"
  done
  run env PATH="$nojq" "$BASH" "$INSTALL" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jq not found; config.json defaults NOT applied"* ]]
  cmp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  [ ! -e "$TARGET/_orch/config.shipped.json" ]
}

@test "an invalid merge result never replaces config.json (validate before rename)" {
  mk_src
  run "$SRC/install.sh" "$TARGET"; [ "$status" -eq 0 ]
  edit "$SRC/_orch/config.json" '.thresholds.brand_new = 5'
  # a merge program that emits garbage as .merged
  cat > "$SRC/scripts/config-merge.jq" <<'JQ'
{merged: "garbage", report: [["+", "x", ""]]}
JQ
  cp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  run "$SRC/install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  cmp "$TARGET/_orch/config.json" "$BATS_TEST_TMPDIR/before.json"
  [[ "$output" == *"defaults NOT applied"* ]]
}

@test "orch status: warns when a managed key is pinned/diverged, silent on a clean install" {
  run "$INSTALL" "$TARGET"; [ "$status" -eq 0 ]
  run "$TARGET/orch" status
  [[ "$output" != *"managed config"* ]]
  edit "$TARGET/_orch/config.json" '.tui_patterns.trust_dialog_regex = $t | .pinned_keys = ["tui_patterns.trust_dialog_regex"]' --arg t "$STALE_TRUST"
  run "$TARGET/orch" status
  [[ "$output" == *"managed config"* ]]
  [[ "$output" == *"tui_patterns.trust_dialog_regex"* ]]
  run "$TARGET/orch" status --json
  [[ "$output" != *"managed config"* ]]
}

@test "config-legacy-defaults.json managed globs match orch status's hard-coded list" {
  run jq -r '.managed | sort | join(",")' "$REPO/scripts/config-legacy-defaults.json"
  [ "$output" = "tui_patterns.askuser_*,tui_patterns.permission_dialog*,tui_patterns.trust_dialog*" ]
  grep -q 'permission_dialog' "$REPO/orch" && grep -q 'trust_dialog' "$REPO/orch" && grep -q 'askuser_' "$REPO/orch"
}
