# Three-way merge of an install's _orch/config.json (issue #202).
# Inputs (--slurpfile, each a 1-element array): $o target's current config.json,
#   $t newly shipped config.json, $b target's config.shipped.json snapshot
#   (--argjson has_base false when absent: bootstrap), $l scripts/config-legacy-defaults.json
#   = {managed: [glob, trailing * = prefix], legacy: {"<leaf.path>": [values ever shipped]}};
#   legacy is consulted only when !$has_base.
# Output: {merged, report: [[sym, path, note], ...]}  sym: + added, ~ updated,
#   = kept operator value, ! managed overwrite, P pinned (kept, managed).
# jq 1.5 only: no walk/IN/abs/toarray, every `if` has an `else`.

$o[0] as $ours | $t[0] as $theirs | $b[0] as $base | $l[0].managed as $managed | $l[0].legacy as $legacy |
def lp($v; $p): if ($v | type) == "object" then ($v | keys_unsorted[]) as $k | lp($v[$k]; $p + [$k]) else $p end;
def hasp($o; $p):
  try ($o | getpath($p[:-1]) | if type == "object" then has($p[-1]) else false end) catch false;
def ismanaged($j):
  [$managed[] | . as $g | if ($g | endswith("*")) then ($j | startswith($g[:-1])) else ($j == $g) end] | any;
def ispinned($j):
  (($ours.pinned_keys // []) | if type == "array" then . else [] end) | [.[] | select(. == $j)] | length > 0;
def fmt: tojson;

reduce lp($theirs; [])  as $p ({m: $ours, r: []};
  ($p | join(".")) as $j
  | ($theirs | getpath($p)) as $t
  # first proper prefix where ours holds a non-object (type conflict with a nested shipped key)
  | ([range(1; ($p | length)) | $p[:.] | . as $q | select(hasp($ours; $q) and (($ours | getpath($q)) | type) != "object")] | first) as $cp
  | if $cp != null then
      .r += [["=", ($cp | join(".")), "type conflict: kept operator value"]]
    elif (hasp($ours; $p) | not) then
      .m = (.m | setpath($p; $t)) | .r += [["+", $j, ""]]
    else
      ($ours | getpath($p)) as $o
      | if ($o | type) == "object" then
          .r += [["=", $j, "type conflict: kept operator value"]]
        elif $o == $t then .
        else
          (if $has_base then hasp($base; $p) else false end) as $inbase
          | (if $inbase then $base | getpath($p) else null end) as $b
          | (if $inbase then $o == $b
             elif $has_base then false
             else (($legacy[$j] // []) | [.[] | select(. == $o)] | length > 0) end) as $unmodified
          | if ismanaged($j) and ispinned($j) then
              .r += [["P", $j, "PINNED, kept operator value"]]
            elif $unmodified then
              .m = (.m | setpath($p; $t)) | .r += [["~", $j, "(shipped default changed)"]]
            elif ismanaged($j) then
              .m = (.m | setpath($p; $t)) | .r += [["!", $j, "MANAGED, overwrote operator value"]]
            elif ($inbase and ($b == $t)) then .
            else
              .r += [["=", $j, "kept operator value (" + ($o | fmt) + "; shipped default is " + ($t | fmt) + ")"]]
            end
        end
    end
)
| {merged: .m, report: .r}
