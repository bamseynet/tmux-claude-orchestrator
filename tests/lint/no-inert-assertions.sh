#!/usr/bin/env bash
# Guard: flags `!`-negated assertions inside a @test body that `set -e`
# does NOT actually enforce (issue #134/#139).
#
# A `!`-negated command is exempt from `set -e`: bash never treats its
# non-zero status as a script failure. `! grep -q pattern file` as the
# LAST statement of a @test body still works, because bats itself checks
# the body's final exit status -- but the same line mid-body is inert:
# its failure is silently swallowed and the test passes regardless.
#
# A `!`-first-token line is exempt from this guard when:
#   (i)   it is the final statement of the @test body (the next
#         non-blank, non-comment line is a bare `}`);
#   (ii)  it carries an explicit failure path on the same line
#         (`|| { ... exit ...}`, `|| { ... return ...}`, `|| exit ...`,
#         `|| return ...`) -- the `!`'s own exemption no longer matters
#         because the `||` branch enforces failure directly;
#   (iii) it (or an unbroken run of comment lines directly above it)
#         carries a waiver: `# inert-ok: <reason>`.
#
# Scope: tests/*.bats only. Deliberately NOT tests/helpers/*.bash --
# tests/helpers/refute.bash:70's own `! kill -0 "$1"` is a correct
# final-statement negation (of refute_alive, not of a @test body), and
# widening this scan to helpers would false-positive on it (issue #139
# §3.2 item 4).
#
# `if !`, `while !`, `until !`, `elif !`, and `run !` are never matched:
# their first token is not `!`.
set -euo pipefail

fail=0
files="$(git ls-files 'tests/*.bats')"
file_count=0

for f in $files; do
  file_count=$((file_count + 1))

  local_refute="$(grep -nE '^refute_[a-zA-Z_]*\(\)' "$f" || true)"
  if [ -n "$local_refute" ]; then
    echo "FAIL: $f defines a local refute_* helper -- use tests/helpers/refute.bash instead:"
    while IFS= read -r hit; do echo "  $hit"; done <<EOF
$local_refute
EOF
    fail=1
  fi

  out="$(awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function is_blank_or_comment(s,   t) {
      t = trim(s)
      return (t == "" || t ~ /^#/)
    }
    { lines[NR] = $0 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (line !~ /^[ \t]*! /) continue
        if (line ~ /#[ \t]*inert-ok:/) continue

        waived = 0
        k = i - 1
        while (k >= 1 && trim(lines[k]) ~ /^#/) {
          if (lines[k] ~ /#[ \t]*inert-ok:/) { waived = 1; break }
          k--
        }
        if (waived) continue

        if (line ~ /\|\|/ && (line ~ /\|\|[ \t]*(\{[ \t]*)?exit([ \t;]|$)/ \
                             || line ~ /\|\|[ \t]*(\{[ \t]*)?return([ \t;]|$)/ \
                             || line ~ /exit[ \t]*[0-9]*[ \t]*;?[ \t]*\}/ \
                             || line ~ /return[ \t]*[0-9]*[ \t]*;?[ \t]*\}/)) continue

        j = i + 1
        while (j <= n && is_blank_or_comment(lines[j])) j++
        nxt = trim(lines[j])
        if (nxt == "}") continue

        printf "%d:%s\n", i, line
      }
    }
  ' "$f")"

  if [ -n "$out" ]; then
    while IFS= read -r hit; do
      lineno="${hit%%:*}"
      text="${hit#*:}"
      echo "FAIL: $f:$lineno: inert \`!\`-negated assertion (not final, no explicit failure path, no # inert-ok: waiver):"
      echo "  $text"
    done <<EOF
$out
EOF
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "One or more inert absence-assertions found (issue #134/#139)."
  echo "Fix: use refute_grep / refute_grep_in_existing / refute_alive from"
  echo "tests/helpers/refute.bash; or make the assertion the @test body's"
  echo "final statement; or add an explicit '|| exit 1' / '|| return 1'"
  echo "failure path; or, if genuinely exempt for another reason, annotate"
  echo "with '# inert-ok: <reason>'."
  exit 1
fi

echo "no-inert-assertions: clean ($file_count files scanned)"
