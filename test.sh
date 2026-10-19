#!/usr/bin/env bash
# Self-contained tests for plonk. Stubs hyprctl; does not talk to a live compositor.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PLONK="$ROOT/plonk"
SERVICE="$ROOT/plonk.service"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v jq >/dev/null || fail "jq is required to run tests"

# A successful ExecStartPre does not skip ExecStart. ExecCondition must fail
# outside Hyprland so systemd leaves the service inactive without starting it.
grep -Fxq "ExecCondition=/bin/sh -c '[ \"\$XDG_CURRENT_DESKTOP\" = \"Hyprland\" ]'" "$SERVICE" ||
  fail "service must use ExecCondition for the Hyprland desktop guard"
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$SERVICE" >/dev/null 2>&1 || fail "invalid systemd unit"
fi
pass "service skips startup outside Hyprland"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# HARD GUARD: tests must never touch the real ~/.config/omarchy/workspace-names.json.
# (2026-08-22: a test run without this remapped Fred's live workspace titles.)
export WORKSPACE_NAMES_FILE="$tmpdir/names-sandbox.json"
export XDG_CONFIG_HOME="$tmpdir/xdg-sandbox"
export PLONK_STATE_DIR="$tmpdir/state-sandbox"
# The suite exercises the change_id path throughout; the default (window
# moves) and the opt-in mechanics have their own checks below.
export PLONK_RENUMBER=change_id
stub="$tmpdir/bin"
log="$tmpdir/hyprctl.log"
mkdir -p "$stub"

write_stub() {
  local active=$1 monitors=$2 workspaces=$3 clients=$4
  cat >"$stub/hyprctl" <<EOF
#!/bin/bash
if [[ -n \${EXPECT_SIG:-} && \${HYPRLAND_INSTANCE_SIGNATURE:-} != "\$EXPECT_SIG" ]]; then
  echo "Couldn't connect (stub: signature \${HYPRLAND_INSTANCE_SIGNATURE:-unset}, expected \$EXPECT_SIG)" >&2; exit 4
fi
case "\$1" in
  activeworkspace) printf '%s\\n' '$active' ;;
  monitors) printf '%s\\n' '$monitors' ;;
  workspaces) printf '%s\\n' '$workspaces' ;;
  clients) printf '%s\\n' '$clients' ;;
  layers) printf '%s\\n' "\${STUB_LAYERS:-{\}}" ;;
  dispatch) printf '%s\\n' "\$*" >>"$log"; echo ok ;;
  eval) printf '%s\\n' "\$*" >>"$log"; echo ok ;;
  *) echo "unexpected hyprctl \$1" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub/hyprctl"
  : >"$log"
}

run_plonk() { PATH="$stub:$PATH" "$PLONK" "$@"; }

# --- --help / bad args never dispatch --------------------------------------
write_stub '{"id":1}' '[]' '[]' '[]'
out=$(run_plonk --help) || fail "--help should exit 0"
[[ $out == "Usage: plonk [-n|--dry-run] [--notify] | plonk --watch [--notify]" ]] || fail "--help prints usage"
[[ ! -s $log ]] || fail "--help does not dispatch"
out=$(env -u HOME -u XDG_CONFIG_HOME PATH="$stub:$PATH" "$PLONK" --help) || fail "--help should work without HOME"
[[ $out == "Usage: plonk [-n|--dry-run] [--notify] | plonk --watch [--notify]" ]] || fail "--help without HOME prints usage"
run_plonk --bogus >/dev/null 2>&1 && fail "unknown flag should exit non-zero" || true
[[ ! -s $log ]] || fail "unknown flag does not dispatch"
run_plonk -n extra >/dev/null 2>&1 && fail "extra args should exit non-zero" || true
pass "rejects unknown args and --help works without a home directory"

# --- already compact -------------------------------------------------------
write_stub '{"id":2}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}}]'
out=$(run_plonk)
[[ $out == "plonk: Already Plonked!" ]] || fail "already compact message, got: $out"
[[ ! -s $log ]] || fail "already compact does not dispatch"
out=$(run_plonk -n)
[[ $out == "plonk: Already Plonked!" ]] || fail "dry-run already compact message, got: $out"
pass "already compact is a no-op, including dry-run"

# --- gap collapse + special skip + refocus ---------------------------------
write_stub '{"id":7}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":7,"name":"7","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":4,"name":"4","monitor":"eDP-1","windows":1},{"id":-99,"name":"special:scratchpad","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":7}},{"address":"0xe","workspace":{"id":-99}}]'
out=$(run_plonk)
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "3 -> 1 via change_id"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "4", id = 2 })' "$log" >/dev/null || fail "4 -> 2 via change_id"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "7", id = 3 })' "$log" >/dev/null || fail "7 -> 3 via change_id"
grep -Fx 'dispatch hl.dsp.focus({ workspace = "3" })' "$log" >/dev/null || fail "refocuses active workspace at new number"
grep -F '0xe' "$log" >/dev/null && fail "leaves special workspaces alone"
grep -F 'window.move' "$log" >/dev/null && fail "does not window.move when change_id is free"
grep -Fx 'plonked workspace 7 -> 3 (eDP-1)' <<<"$out" >/dev/null || fail "prints the move, got: $out"
pass "collapses gaps with change_id, skips special, refocuses"

# If focus changes after the snapshot but before the final refocus, never pull
# the user back to the workspace plonk started on.
focus_calls="$tmpdir/focus-active.calls"
printf '0\n' >"$focus_calls"
cat >"$stub/hyprctl" <<STUB
#!/bin/bash
case "\$1" in
  activeworkspace)
    n=\$(cat "$focus_calls"); n=\$((n + 1)); printf '%s\n' "\$n" >"$focus_calls"
    if ((n <= 2)); then printf '%s\n' '{"id":7}'; else printf '%s\n' '{"id":9}'; fi ;;
  monitors) printf '%s\n' '[{"name":"eDP-1"}]' ;;
  workspaces) printf '%s\n' '[{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":7,"name":"7","monitor":"eDP-1","windows":1}]' ;;
  clients) printf '%s\n' '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":7}}]' ;;
  dispatch) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  eval) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  *) echo "unexpected hyprctl \$1" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/hyprctl"
: >"$log"
run_plonk >/dev/null
grep -F 'change_id' "$log" >/dev/null || fail "focus-race fixture must compact, log=$(cat "$log")"
grep -F 'hl.dsp.focus' "$log" >/dev/null && fail "must not steal focus after the user switched, log=$(cat "$log")"
pass "does not refocus from a stale active-workspace snapshot"

# Restore the gap fixture used by the title-remap checks below.
write_stub '{"id":7}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":7,"name":"7","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":4,"name":"4","monitor":"eDP-1","windows":1},{"id":-99,"name":"special:scratchpad","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":7}},{"address":"0xe","workspace":{"id":-99}}]'

# --- workspace-names.json titles travel with the workspace ------------------
names="$tmpdir/workspace-names.json"
printf '%s\n' '{"_config":{"hold":900},"3":"Brave","4":"Voice","7":"Blank","9":"Stale"}' >"$names"
: >"$log"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -r '."1"' "$names") == Brave ]] || fail "3 -> 1 carries 'Brave' onto an unnamed slot, got: $(cat "$names")"
[[ $(jq -r '."2"' "$names") == Voice ]] || fail "4 -> 2 carries 'Voice', got: $(cat "$names")"
[[ $(jq -r '."3"' "$names") == Blank ]] || fail "7 -> 3 carries 'Blank' (overwriting stale 'Brave'), got: $(cat "$names")"
[[ $(jq -r 'has("4")' "$names") == false && $(jq -r 'has("7")' "$names") == false ]] || fail "old keys removed, got: $(cat "$names")"
[[ $(jq -r '."9"' "$names") == Stale ]] || fail "names of workspaces plonk did not touch stay put"
[[ $(jq -r '._config.hold' "$names") == 900 ]] || fail "_config preserved"
ls "$tmpdir"/workspace-names.json.* >/dev/null 2>&1 && fail "no temp files left behind"
grep -F 'rename' "$log" >/dev/null && fail "never touches Hyprland workspace names"
pass "workspace-names.json titles travel with renumbered workspaces"

# A title on a workspace that NO LONGER EXISTS releases its number (1.2.4).
# Reserving it forever is what made the bar read "2 4" while plonk reported
# "Already Plonked!". The displaced title is archived, never overwritten.
printf '%s\n' '{"1":"Reserved project","3":"Brave","4":"Voice","7":"Blank"}' >"$names"
: >"$log"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS 'with_entries(select(.key|test("^[0-9]+$")))' "$names") == '{"1":"Brave","2":"Voice","3":"Blank"}' ]] ||
  fail "a title whose workspace is gone must not hold its number: $(cat "$names")"
[[ $(jq -c '[._plonk_archived_names[].name]' "$names") == '["Reserved project"]' ]] ||
  fail "the displaced title must be archived, not lost: $(cat "$names")"
grep -F 'id = 1 })' "$log" >/dev/null || fail "slot 1 must be reused once its title stops reserving it"
pass "a title on a vanished workspace releases its number and is archived"

# A title on a LIVE but empty workspace still holds its number. This is the
# half of the old behaviour worth keeping: you named a workspace you are using,
# nobody steals its number while it exists.
track="$tmpdir/state-sandbox/window-owners.json"
mkdir -p "$tmpdir/state-sandbox"
write_stub '{"id":3}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":3}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":0},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Deploys","3":"Work"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
grep -F 'plonked workspace 3 -> 2' <<<"$out" >/dev/null ||
  fail "a live empty workspace must keep its titled number, got: $out"
[[ $(jq -r '."1"' "$names") == Deploys ]] || fail "the live slot's title must stay: $(cat "$names")"
pass "a title on a live empty workspace still reserves its number"

# A title parked on a workspace that does not exist YET, above the pack, is
# left completely alone — pre-labelling slots you have not opened is a real
# workflow and plonk must not sweep it into the archive on sight.
write_stub '{"id":1}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Mail","2":"Code","9":"Music"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"Mail","2":"Code","9":"Music"}' ]] ||
  fail "a pre-labelled slot above the pack must be untouched: $(cat "$names")"
pass "a title for a workspace that does not exist yet is left alone"

# Fred 2026-09-10, the reported bug end to end: the bar read "2 4" because
# titles typed on workspaces 1 and 3 — both long closed — reserved those
# numbers, and plonk reported "Already Plonked!" over a visible gap.
write_stub '{"id":4}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":4}}]' \
  '[{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":2},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":2}},{"address":"0xb","workspace":{"id":4}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":5}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Herdr","2":"Brave","3":"Launcher fix","4":"Terminal","5":"vic: plonk","_auto":["4","5"]}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
for m in 'workspace 2 -> 1' 'workspace 4 -> 2' 'workspace 5 -> 3'; do
  grep -F "$m" <<<"$out" >/dev/null || fail "the reported gap must close ($m), got: $out"
done
[[ $(jq -cS 'with_entries(select(.key|test("^[0-9]+$")))' "$names") == '{"1":"Brave","2":"Terminal","3":"vic: plonk"}' ]] ||
  fail "titles must ride the compaction: $(cat "$names")"
[[ $(jq -c '[._plonk_archived_names[].name]|sort' "$names") == '["Herdr","Launcher fix"]' ]] ||
  fail "the two displaced titles must be archived, not lost: $(cat "$names")"
pass "the reported \"2 4\" gap closes and both displaced titles are archived"

# an UNNAMED workspace arriving on a slot never deletes the slot's title
# (titles are sticky; plonk must never remove a name on its own)
write_stub '{"id":7}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":7,"name":"7","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":4,"name":"4","monitor":"eDP-1","windows":1},{"id":-99,"name":"special:scratchpad","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":7}},{"address":"0xe","workspace":{"id":-99}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Keep","2":"Me"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -c . "$names") == '{"1":"Keep","2":"Me"}' ]] || fail "unnamed arrivals must not touch existing titles, got: $(cat "$names")"
pass "plonk never deletes a title on its own"
ls "$tmpdir/state-sandbox/names-backups"/workspace-names.*.json >/dev/null 2>&1 || fail "a names backup is written before any remap"
pass "names file is backed up before plonk rewrites it"

# --- a title follows its windows -------------------------------------------
# SUPER+SHIFT+5 moves the last window off workspace 3: the workspace dies and
# its title must land where the window did, not rot on the old number.
track="$tmpdir/state-sandbox/window-owners.json"
mkdir -p "$tmpdir/state-sandbox"
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
[[ $(jq -cS . "$names") == '{"1":"Home","2":"Brave"}' ]] || fail "title must follow its window (3 -> 5 -> compacted to 2), got: $(cat "$names")"
grep -F 'carried title "Brave" 3 -> 5' <<<"$out" >/dev/null || fail "the carry must be reported, got: $out"
pass "a title follows its windows when the last one is moved away"

# The map is written for the NEXT round: after the compact above the window
# lives on 2, so a later move is measured from there.
[[ $(jq -r '."0xa"' "$track") == 5 ]] || fail "window-owner map must be refreshed after a compact, got: $(cat "$track")"
pass "window-owner map is refreshed after every compact"

# A window that was CLOSED (not moved) carries nothing: the title stays put.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"Home","3":"Brave"}' ]] || fail "a closed window must not move a title, got: $(cat "$names")"
pass "closing the last window leaves the title where it was"

# The destination's own title always wins, and the absorbed one is dropped:
# its windows now live under "Mine", so "Brave" describes nothing and must not
# keep reserving the empty 3.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave","5":"Mine"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
[[ $(jq -cS . "$names") == '{"1":"Home","2":"Mine"}' ]] || fail "an incoming title must not overwrite the destination's own, and must not linger, got: $(cat "$names")"
grep -F 'dropped title "Brave" 3 (5 already titled)' <<<"$out" >/dev/null || fail "the drop must be reported, got: $out"
pass "a title absorbed by an already-titled workspace is dropped, not stranded"

# The dropped title frees its number: 3 no longer reserves a slot, so the
# workspace that used to compact to 4 now lands on 3.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}},{"address":"0xc","workspace":{"id":9}}]'
printf '%s\n' '{"0xa":3,"0xb":1,"0xc":9}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave","5":"Mine"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
[[ $(jq -r 'has("3")' "$names") == false ]] || fail "the absorbed title must not survive, got: $(cat "$names")"
grep -F 'dropped title "Brave" 3' <<<"$out" >/dev/null || fail "the drop must be reported, got: $out"
pass "a dropped title stops reserving its number"

# An automatic source title absorbed the same way is dropped too, and takes
# its "_auto" mark with it.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"AutoLabel","5":"Mine","_auto":["3"]}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"Home","2":"Mine"}' ]] || fail "an absorbed automatic label must be dropped with its mark, got: $(cat "$names")"
pass "an absorbed automatic label is dropped with its _auto mark"

# A CLOSED window still moves and drops nothing, even with the destination
# titled — only titles whose windows actually went somewhere are absorbed.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xd","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1,"0xd":5}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave","5":"Mine"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -r '.["3"] // .["2"] // ""' "$names") == "Brave" || $(jq -r '[.[]|strings]|index("Brave")' "$names") != null ]] || fail "a closed window must not drop a title, got: $(cat "$names")"
pass "closing the last window drops no title even when the destination is titled"

# --dry-run plans the carry and writes nothing.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"Brave"}' >"$names"
before=$(cat "$names")
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk --dry-run)
grep -F 'would carry title "Brave" 3 -> 5' <<<"$out" >/dev/null || fail "dry run must plan the carry, got: $out"
[[ $(cat "$names") == "$before" ]] || fail "dry run must not touch the names file"
[[ $(jq -r '."0xa"' "$track") == 3 ]] || fail "dry run must not touch the window-owner map"
pass "--dry-run plans the carry without writing"

# A planted symlink at the map path is never followed or written through.
canary_map="$tmpdir/canary-map.json"; printf '{"0xz":9}\n' >"$canary_map"
rm -f "$track"; ln -s "$canary_map" "$track"
printf '%s\n' '{"1":"Home"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null 2>&1
[[ $(cat "$canary_map") == '{"0xz":9}' ]] || fail "a symlinked window-owner map must never be written through"
rm -f "$track"
pass "window-owner map is never written through a symlink"

# --- automatic titles never outrank the ones you typed ----------------------
# The workspace-names plugin names an unnamed workspace from its window titles
# within a second, so "the destination already has a title" cannot be what
# stops a carry — it would make this a race the automatic name usually wins.
# Titles it wrote are listed in "_auto".

# A typed title displaces an automatic one at the destination.
write_stub '{"id":5}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xb","workspace":{"id":1}},{"address":"0xa","workspace":{"id":5}}]'
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"Typed","5":"AutoLabel","_auto":["5"]}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"Home","2":"Typed"}' ]] || fail "a typed title must displace an automatic one, got: $(cat "$names")"
pass "a typed title displaces an automatic title at the destination"

# ...and never the other way round.
printf '%s\n' '{"0xa":3,"0xb":1}' >"$track"
printf '%s\n' '{"1":"Home","3":"AutoLabel","5":"Typed","_auto":["3"]}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"Home","2":"Typed"}' ]] || fail "an automatic title must not displace a typed one, got: $(cat "$names")"
pass "an automatic title never displaces a typed one"

# An automatic label reserves no number: it would leave a permanent gap for
# every workspace that ever held a window.
write_stub '{"id":3}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":0},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"AutoLabel","_auto":["1"]}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
grep -F 'plonked workspace 3 -> 1' <<<"$out" >/dev/null || fail "an automatic label must not reserve a slot, got: $out"
printf '%s\n' '{"1":"Typed"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
grep -F 'plonked workspace 3 -> 2' <<<"$out" >/dev/null || fail "a typed title must still reserve its slot, got: $out"
pass "automatic labels reserve no slot; typed titles still do"

# A dead automatic label is litter, not history: dropped, never archived.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Typed","3":"AutoLabel","4":"TypedGone","_auto":["3"]}' >"$names"
PLONK_EMPTY_NAMES=archive WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -r 'has("3")' "$names") == false && $(jq -r 'has("_auto")' "$names") == false ]] || fail "a dead automatic label must be dropped, got: $(cat "$names")"
[[ $(jq -c '[._plonk_archived_names[].name]' "$names") == '["TypedGone"]' ]] || fail "only typed titles are archived, got: $(cat "$names")"
pass "a vanished workspace's automatic label is dropped, its typed title archived"

# The mark travels with a renumber, or a renumbered automatic label would
# start outranking the titles you typed.
write_stub '{"id":3}' '[{"name":"eDP-1"}]' \
  '[{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"3":"AutoLabel","_auto":["3"]}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -cS . "$names") == '{"1":"AutoLabel","_auto":["1"]}' ]] || fail "the automatic mark must follow the renumber, got: $(cat "$names")"
pass "the automatic mark follows its title through a renumber"

# notifications are OPT-IN (Fred 2026-09-04: "it should just do its work
# without reporting a notification"). Without --notify nothing is sent, even
# when a notifier is on PATH and even for a no-op run.
cat >"$stub/omarchy-notification-send" <<'EOF3'
#!/bin/bash
echo "notify $*" >>"$NOTIFY_LOG"
EOF3
chmod +x "$stub/omarchy-notification-send"
nlog="$tmpdir/notify.log"; : >"$nlog"
rm -f "$tmpdir/state-sandbox/last-notify"
NOTIFY_LOG="$nlog" run_plonk >/dev/null
write_stub '{"id":1}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}}]'
NOTIFY_LOG="$nlog" run_plonk >/dev/null
[[ ! -s $nlog ]] || fail "plonk must be silent without --notify, got: $(cat "$nlog")"
[[ ! -e $tmpdir/state-sandbox/last-notify ]] || fail "no notify stamp may be written without --notify"
pass "no desktop notification unless --notify"

# with --notify they coalesce: three runs inside 2s -> one notification
write_stub '{"id":7}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":7,"name":"7","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":7}}]'
: >"$nlog"
rm -f "$tmpdir/state-sandbox/last-notify"
NOTIFY_LOG="$nlog" run_plonk --notify >/dev/null
NOTIFY_LOG="$nlog" run_plonk --notify >/dev/null
NOTIFY_LOG="$nlog" run_plonk --notify >/dev/null
[[ $(grep -c '^notify' "$nlog") == 1 ]] || fail "three --notify runs within 2s must notify once, got: $(cat "$nlog")"
grep -F 'Plonked 3 workspaces' "$nlog" >/dev/null || fail "--notify uses plonk as a verb, got: $(cat "$nlog")"
pass "--notify notifications coalesce to one per 2s"
rm -f "$stub/omarchy-notification-send"

# --- hardening from marketplace review #2941 ---------------------------------
# The lock must never open a predictable path for writing: a symlink planted
# at the old lock location must not be followed or truncated.
canary="$tmpdir/canary.txt"; printf 'CANARY\n' >"$canary"
mkdir -p "$tmpdir/state-sandbox"; rm -f "$tmpdir/state-sandbox/lock"
ln -s "$canary" "$tmpdir/state-sandbox/lock"
run_plonk >/dev/null 2>&1
[[ $(cat "$canary") == CANARY ]] || fail "a symlink at the old lock path was followed and truncated"
[[ -L $tmpdir/state-sandbox/lock ]] && rm -f "$tmpdir/state-sandbox/lock"
pass "lock never writes through a planted symlink"

# A symlinked names file is never followed: the target stays untouched.
target="$tmpdir/names-target.json"; printf '%s\n' '{"3":"Brave"}' >"$target"
ln -sf "$target" "$tmpdir/names-link.json"
err=$(WORKSPACE_NAMES_FILE="$tmpdir/names-link.json" run_plonk 2>&1 >/dev/null) || fail "symlinked names file must not break the compact"
[[ $(jq -c . "$target") == '{"3":"Brave"}' ]] || fail "symlinked names file was followed and rewritten: $(cat "$target")"
grep -F 'titles NOT remapped' <<<"$err" >/dev/null || fail "symlinked names file must be reported, got: $err"
pass "symlinked names file is left alone and reported"

# A FIFO at the names path must not block the run (jq would wait for a
# writer forever, wedging the watcher).
mkfifo "$tmpdir/names.fifo"
WORKSPACE_NAMES_FILE="$tmpdir/names.fifo" PATH="$stub:$PATH" timeout 5 "$PLONK" >/dev/null 2>&1 || fail "a FIFO at the names path blocked or failed the run (rc=$?)"
rm -f "$tmpdir/names.fifo"
pass "FIFO at the names path does not block plonk"

# An oversized names file is never parsed, however valid it is.
big="$tmpdir/names-big.json"
{ printf '{"3":"Brave","pad":"'; head -c 1200000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } >"$big"
before=$(stat -c %s "$big")
err=$(WORKSPACE_NAMES_FILE="$big" run_plonk 2>&1 >/dev/null) || fail "oversized names file must not break the compact"
[[ $(stat -c %s "$big") == "$before" ]] || fail "oversized names file was rewritten"
grep -F 'titles NOT remapped' <<<"$err" >/dev/null || fail "oversized names file must be reported, got: $err"
pass "oversized names file is skipped and reported"

# --- renumber strategy: window moves by default, change_id opt-in -----------
# Quickshell 0.3.1 ignores changeworkspaceid, so the stock Omarchy bar shows
# the old number as a ghost after change_id. The default must therefore move
# windows; change_id is opt-in via env or ~/.config/plonk/renumber.
write_stub '{"id":7}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":7,"name":"7","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":2},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":7}}]'
env -u PLONK_RENUMBER PATH="$stub:$PATH" "$PLONK" >/dev/null || fail "default run must succeed"
grep -F 'change_id' "$log" >/dev/null && fail "default must not use change_id, log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.window.move({ window = "address:0xa", workspace = "1", follow = false })' "$log" >/dev/null ||
  fail "default must move windows, log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.workspace.move({ workspace = "1", monitor = "eDP-1" })' "$log" >/dev/null ||
  fail "default must pin the new workspace to its monitor, log=$(cat "$log")"
pass "renumbers by moving windows unless change_id is opted in"

mkdir -p "$XDG_CONFIG_HOME/plonk"
printf 'change_id\n' >"$XDG_CONFIG_HOME/plonk/renumber"
: >"$log"
env -u PLONK_RENUMBER PATH="$stub:$PATH" "$PLONK" >/dev/null || fail "config-file run must succeed"
grep -F 'change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "renumber file must enable change_id, log=$(cat "$log")"
grep -F 'window.move' "$log" >/dev/null && fail "change_id mode must not move windows, log=$(cat "$log")"
pass "~/.config/plonk/renumber opts into change_id"

rm -f "$XDG_CONFIG_HOME/plonk/renumber"; printf 'change_id\n' >"$tmpdir/renumber-target"
ln -s "$tmpdir/renumber-target" "$XDG_CONFIG_HOME/plonk/renumber"
: >"$log"
env -u PLONK_RENUMBER PATH="$stub:$PATH" "$PLONK" >/dev/null || fail "symlinked renumber file run must succeed"
grep -F 'change_id' "$log" >/dev/null && fail "a symlinked renumber file must be ignored, log=$(cat "$log")"
pass "symlinked renumber file is ignored"

rm -f "$XDG_CONFIG_HOME/plonk/renumber"; printf 'teleport\n' >"$XDG_CONFIG_HOME/plonk/renumber"
: >"$log"
err=$(env -u PLONK_RENUMBER PATH="$stub:$PATH" "$PLONK" 2>&1 >/dev/null) || fail "invalid renumber mode must not fail the run"
grep -F 'unknown renumber mode' <<<"$err" >/dev/null || fail "invalid renumber mode must be reported, got: $err"
grep -F 'window.move' "$log" >/dev/null || fail "invalid renumber mode must fall back to moving windows, log=$(cat "$log")"
pass "unknown renumber mode warns and moves windows"
rm -f "$XDG_CONFIG_HOME/plonk/renumber"
: >"$log"
env PLONK_RENUMBER=change_id PATH="$stub:$PATH" "$PLONK" >/dev/null
grep -F 'change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "PLONK_RENUMBER=change_id must enable change_id, log=$(cat "$log")"
pass "PLONK_RENUMBER=change_id opts into change_id"

# names file missing -> no-op, no error
: >"$log"
WORKSPACE_NAMES_FILE="$tmpdir/does-not-exist.json" run_plonk >/dev/null || fail "missing names file must not fail"
[[ ! -e "$tmpdir/does-not-exist.json" ]] || fail "does not create a names file"
pass "no names file is fine"

# XDG_CONFIG_HOME is the standard config root and HOME may be absent in a
# minimal service environment.
# Titles travel: if the XDG-path file is honored, the title on 3 rides along
# to slot 1 (the suite's global WORKSPACE_NAMES_FILE must be unset here).
mkdir -p "$tmpdir/xdg/omarchy"
printf '%s\n' '{"3":"XDG title"}' >"$tmpdir/xdg/omarchy/workspace-names.json"
env -u HOME -u WORKSPACE_NAMES_FILE XDG_CONFIG_HOME="$tmpdir/xdg" PATH="$stub:$PATH" "$PLONK" >/dev/null || fail "runs without HOME when XDG_CONFIG_HOME is set"
[[ $(jq -r '."1"' "$tmpdir/xdg/omarchy/workspace-names.json") == "XDG title" ]] || fail "uses workspace names from XDG_CONFIG_HOME, got: $(cat "$tmpdir/xdg/omarchy/workspace-names.json")"
pass "workspace title path follows XDG_CONFIG_HOME without requiring HOME"

# --- dry run prints the plan and dispatches nothing ------------------------
: >"$log"
out=$(run_plonk --dry-run)
[[ -s $log ]] && fail "dry run does not dispatch"
grep -Fx 'would plonk workspace 7 -> 3 (eDP-1)' <<<"$out" >/dev/null || fail "dry run prints the plan, got: $out"
pass "dry run only prints the plan"

# --- multi-monitor: global IDs, no collision -------------------------------
# eDP-1 has 3,5; HDMI-1 has 7,8. Restarting target=1 per monitor would move
# HDMI's 7 onto eDP's new 1. Compact globally: 3->1, 5->2, 7->3, 8->4.
write_stub '{"id":7}' \
  '[{"name":"eDP-1"},{"name":"HDMI-1"}]' \
  '[{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":5,"name":"5","monitor":"eDP-1","windows":1},{"id":7,"name":"7","monitor":"HDMI-1","windows":1},{"id":8,"name":"8","monitor":"HDMI-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":5}},{"address":"0xc","workspace":{"id":7}},{"address":"0xd","workspace":{"id":8}}]'
out=$(run_plonk)
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "eDP 3 -> 1"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "5", id = 2 })' "$log" >/dev/null || fail "eDP 5 -> 2"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "7", id = 3 })' "$log" >/dev/null || fail "HDMI 7 -> 3 (not 1)"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "8", id = 4 })' "$log" >/dev/null || fail "HDMI 8 -> 4 (not 2)"
grep -E 'change_id\(\{ workspace = "7", id = 1 \}\)' "$log" >/dev/null && fail "must not collide HDMI onto workspace 1"
grep -Fx 'dispatch hl.dsp.focus({ workspace = "3" })' "$log" >/dev/null || fail "refocus HDMI active 7 at 3"
pass "multi-monitor fills global holes without stealing the other head"

# --- named workspaces left alone ------------------------------------------
write_stub '{"id":1}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":82345,"name":"mail","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":82345}}]'
out=$(run_plonk)
[[ $out == "plonk: Already Plonked!" ]] || fail "named workspace is not compacted, got: $out"
grep -F '82345' "$log" >/dev/null && fail "does not touch named workspaces"
pass "named workspaces are left alone"

# A renamed workspace occupying id 2 must not be a landing slot (3,4 -> 1,3).
write_stub '{"id":3}' \
  '[{"name":"eDP-1"}]' \
  '[{"id":2,"name":"mail","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xmail","workspace":{"id":2}},{"address":"0xa","workspace":{"id":3}},{"address":"0xb","workspace":{"id":4}}]'
out=$(run_plonk)
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "packs around a named workspace occupying a low id"
grep -E 'id = 2' "$log" >/dev/null && fail "must not land on a named workspace's id, log=$(cat "$log")"
grep -F '0xmail' "$log" >/dev/null && fail "must not move windows onto a named workspace"
pass "skips named-workspace ids when packing"

# --- empty persistent target: window.move + pin to original monitor --------
write_stub '{"id":3}' \
  '[{"name":"HDMI-1"}]' \
  '[{"id":1,"name":"1","monitor":"HDMI-1","windows":0},{"id":3,"name":"3","monitor":"HDMI-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":3}}]'
out=$(run_plonk)
grep -F 'change_id' "$log" >/dev/null && fail "does not change_id onto a taken empty workspace"
grep -Fx 'dispatch hl.dsp.window.move({ window = "address:0xa", workspace = "1", follow = false })' "$log" >/dev/null || fail "moves the window onto empty persistent 1"
grep -Fx 'dispatch hl.dsp.workspace.move({ workspace = "1", monitor = "HDMI-1" })' "$log" >/dev/null || fail "pins dest workspace to original monitor"
pass "falls back to window.move when the target ID is already taken"

# --- change_id that fails with exit 0 -------------------------------------
# Hyprland prints "warning: ... " and still exits 0 when change_id cannot run
# (workspace vanished mid-compact, id grabbed by a race). Only the literal
# "ok" is success; anything else must take the window-move fallback — and
# never remap a title for a renumber that did not happen.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":3}}]'
sed -i 's|dispatch) printf|dispatch) case "$2" in *change_id*) printf "%s\\n" "$*" >>"'"$log"'"; echo "warning: =[C]:-1: hl.workspace.change_id: no such workspace"; exit 0;; esac; printf|' "$stub/hyprctl"
printf '%s\n' '{"3":"Riding"}' >"$tmpdir/liar-names.json"
WORKSPACE_NAMES_FILE="$tmpdir/liar-names.json" run_plonk >/dev/null
grep -Fx 'dispatch hl.dsp.window.move({ window = "address:0xb", workspace = "2", follow = false })' "$log" >/dev/null ||
  fail "lying change_id (warning, exit 0) must fall back to window.move, log=$(cat "$log")"
[[ $(jq -r '."2"' "$tmpdir/liar-names.json") == Riding ]] ||
  fail "title must follow the fallback move, got: $(cat "$tmpdir/liar-names.json")"
pass "change_id failure with exit 0 is detected; fallback moves windows and title"

# --- invalid active workspace JSON ----------------------------------------
write_stub '{"id":null}' '[]' '[]' '[]'
run_plonk >/dev/null 2>&1 && fail "null active id should fail" || true
pass "rejects a null active workspace id"

# --- --watch: event filtering, empty-active guard, quiet -------------------
command -v socat >/dev/null || fail "socat is required for --watch tests"
command -v timeout >/dev/null || fail "timeout is required for --watch tests"

HOLE_GONE='[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]'
HOLE_SITTING='[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":0},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]'
HOLE_CLIENTS='[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}}]'

start_event_socket() {
  local sockpath=$1 data=$2
  mkdir -p "$(dirname "$sockpath")"
  rm -f "$sockpath"
  printf '%s' "$data" >"$tmpdir/events.bin"
  socat UNIX-LISTEN:"$sockpath",unlink-early SYSTEM:"cat '$tmpdir/events.bin'; sleep 0.7" &
  local i
  for i in $(seq 1 40); do
    [[ -S $sockpath ]] && return 0
    sleep 0.05
  done
  fail "event socket did not appear at $sockpath"
}

run_watch_once() {
  XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig \
    PATH="$stub:$PATH" timeout 3 "$PLONK" --watch 2>/dev/null || true
}

SOCK="$tmpdir/hypr/watchsig/.socket2.sock"

# Switching onto an empty workspace must not compact (would dump 3 onto 2).
write_stub '{"id":2}' '[{"name":"eDP-1"}]' "$HOLE_SITTING" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'workspace>>2\n'
out=$(run_watch_once)
[[ -s $log ]] && fail "watch ignores workspace switch events, log=$(cat "$log")"
pass "watch does not compact on workspace switch"

# Leaving/destroying a workspace does compact when the active one is occupied.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'destroyworkspace>>2\n'
out=$(run_watch_once)
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "watch compact on destroyworkspace, log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "4", id = 3 })' "$log" >/dev/null ||
  fail "watch packs the rest after destroyworkspace"
[[ $out != *plonked* ]] || fail "watch is quiet, got: $out"
pass "watch compacts on destroyworkspace and stays quiet"

# The compositor can replace its event socket without ending the graphical
# session.  The watcher must reconnect itself rather than exit and rely on
# systemd to notice the gap.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
: >"$log"
rm -f "$SOCK"
printf '%s\n' 'workspace>>2' >"$tmpdir/reconnect-1.events"
printf '%s\n' 'destroyworkspace>>2' >"$tmpdir/reconnect-2.events"
(
  socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"cat '$tmpdir/reconnect-1.events'"
  sleep 0.2
  socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"cat '$tmpdir/reconnect-2.events'; sleep 0.5"
) &
server_pid=$!
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_RECONNECT_DELAY=0.1 \
  PATH="$stub:$PATH" timeout 3 "$PLONK" --watch >/dev/null 2>&1 || true
wait "$server_pid" 2>/dev/null || true
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "watch reconnects after event socket replacement, log=$(cat "$log")"
pass "watch reconnects when Hyprland replaces its event socket"

# Sitting on the empty hole: compact must not fill it (skip target 2).
write_stub '{"id":2}' '[{"name":"eDP-1"}]' "$HOLE_SITTING" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'destroyworkspace>>9\n'
out=$(run_watch_once)
grep -F 'change_id' "$log" >/dev/null && fail "watch must not fill the empty active workspace, log=$(cat "$log")"
grep -F 'window.move' "$log" >/dev/null && fail "watch must not dump windows onto the empty active workspace"
pass "watch leaves the empty workspace you are sitting on alone"

# empty_active=fill: the workspace under the user emptied -> jump to the next
# occupied workspace on that monitor right away (Hyprland drops the empty
# one and the next round renumbers), instead of waiting for them to leave.
write_stub '{"id":2}' '[{"name":"eDP-1"}]' "$HOLE_SITTING" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'closewindow>>b\n'
PLONK_EMPTY_ACTIVE=fill PLONK_FILL_DELAY_MS=0 run_watch_once >/dev/null
grep -Fx 'dispatch hl.dsp.focus({ workspace = "3" })' "$log" >/dev/null ||
  fail "fill must jump to the next occupied workspace, log=$(cat "$log")"
grep -F 'window.move' "$log" >/dev/null && fail "fill must jump, not dump windows under the user, log=$(cat "$log")"
grep -F 'change_id' "$log" >/dev/null && fail "fill must not renumber onto the workspace the user is on, log=$(cat "$log")"
pass "empty_active=fill jumps to the next occupied workspace immediately"

# Fred 2026-09-10, vic: "Plonk not closing up workspace 1?" — the bar read
# [1 empty, you are on it] [2] [3] [4] and 2/3/4 never shifted down. Workspace 1
# is the bottom of the number line, so this is the fill path at its edge.
WS1_EMPTY='[{"id":1,"name":"1","monitor":"eDP-1","windows":0},{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]'
WS1_CLIENTS='[{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}},{"address":"0xd","workspace":{"id":4}}]'
write_stub '{"id":1}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}}]' "$WS1_EMPTY" "$WS1_CLIENTS"
start_event_socket "$SOCK" $'closewindow>>a\n'
PLONK_EMPTY_ACTIVE=fill PLONK_FILL_DELAY_MS=0 run_watch_once >/dev/null
grep -Fx 'dispatch hl.dsp.focus({ workspace = "2" })' "$log" >/dev/null ||
  fail "emptying workspace 1 under you must jump to 2, log=$(cat "$log")"
pass "empty_active=fill works at the bottom of the number line (workspace 1)"

# ...but stands down if the user already left during the grace (the third
# activeworkspace read is the post-grace re-check).
fill_calls="$tmpdir/fill-active.calls"; printf '0\n' >"$fill_calls"
cat >"$stub/hyprctl" <<STUB
#!/bin/bash
case "\$1" in
  activeworkspace)
    n=\$(cat "$fill_calls"); n=\$((n + 1)); printf '%s\n' "\$n" >"$fill_calls"
    if ((n <= 2)); then printf '%s\n' '{"id":2}'; else printf '%s\n' '{"id":1}'; fi ;;
  monitors) printf '%s\n' '[{"name":"eDP-1"}]' ;;
  workspaces) printf '%s\n' '$HOLE_SITTING' ;;
  clients) printf '%s\n' '$HOLE_CLIENTS' ;;
  layers) printf '%s\n' '{}' ;;
  dispatch) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  eval) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  *) echo "unexpected hyprctl \$1" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/hyprctl"
: >"$log"
start_event_socket "$SOCK" ''
PLONK_EMPTY_ACTIVE=fill PLONK_FILL_DELAY_MS=0 run_watch_once >/dev/null
grep -F 'hl.dsp.focus' "$log" >/dev/null && fail "fill must stand down when the user already left, log=$(cat "$log")"
pass "fill stands down when the user leaves during the grace"

# The same switch from the config file (plugin users have no env).
write_stub '{"id":2}' '[{"name":"eDP-1"}]' "$HOLE_SITTING" "$HOLE_CLIENTS"
mkdir -p "$XDG_CONFIG_HOME/plonk"
printf '# plonk\nempty_active = fill\nrenumber=change_id\nbogus=1\n' >"$XDG_CONFIG_HOME/plonk/config"
start_event_socket "$SOCK" ''
err=$(XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_FILL_DELAY_MS=0 \
  PATH="$stub:$PATH" env -u PLONK_RENUMBER timeout 3 "$PLONK" --watch 2>&1 >/dev/null || true)
grep -Fx 'dispatch hl.dsp.focus({ workspace = "3" })' "$log" >/dev/null ||
  fail "config file empty_active=fill must be honored, log=$(cat "$log")"
grep -F "unknown option 'bogus'" <<<"$err" >/dev/null || fail "unknown config keys must be reported, got: $err"
rm -f "$XDG_CONFIG_HOME/plonk/config"
pass "~/.config/plonk/config drives empty_active and reports unknown keys"

# A steady stream of windowtitle events (terminal spinners, browsers) must
# not starve the watcher: the settle window is wall-clock bounded, so the
# compact still happens while titles keep flowing.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
: >"$log"
rm -f "$SOCK"
cat >"$tmpdir/flood.sh" <<'FLOOD'
exec 2>/dev/null
echo 'movewindow>>0xb,1'
i=0
while [ "$i" -lt 250 ]; do echo 'windowtitle>>0xa'; sleep 0.01; i=$((i+1)); done
FLOOD
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/flood.sh'" &
flood_pid=$!
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
# The flood runs ~2.5s; the compact must land well before it ends.
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig \
  PATH="$stub:$PATH" timeout 1.5 "$PLONK" --watch >/dev/null 2>&1 || true
kill "$flood_pid" 2>/dev/null; wait "$flood_pid" 2>/dev/null || true
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "watch starved by continuous windowtitle events, log=$(cat "$log")"
pass "watch compacts while windowtitle events stream continuously"

# A hole that opens during the post-compact settle window must not be lost.
# Stateful stub: workspaces come from a file the event generator swaps while
# the watcher is settling after a no-op compact.
COMPACT_WS='[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1}]'
printf '%s\n' "$COMPACT_WS" >"$tmpdir/ws.json"
printf '%s\n' "$HOLE_GONE" >"$tmpdir/ws-hole.json"
cat >"$stub/hyprctl" <<STUB
#!/bin/bash
case "\$1" in
  activeworkspace) printf '%s\\n' '{"id":1}' ;;
  monitors) printf '%s\\n' '[{"name":"eDP-1"}]' ;;
  workspaces) cat "$tmpdir/ws.json" ;;
  clients) printf '%s\\n' '$HOLE_CLIENTS' ;;
  dispatch) printf '%s\\n' "\$*" >>"$log"; echo ok ;;
  eval) printf '%s\\n' "\$*" >>"$log"; echo ok ;;
  *) echo "unexpected hyprctl \$1" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/hyprctl"
: >"$log"
rm -f "$SOCK"
cat >"$tmpdir/late-hole.sh" <<GEN
exec 2>/dev/null
echo 'destroyworkspace>>9'
sleep 0.4
cp '$tmpdir/ws-hole.json' '$tmpdir/ws.json'
echo 'destroyworkspace>>2'
sleep 1.2
GEN
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/late-hole.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig \
  PATH="$stub:$PATH" timeout 2 "$PLONK" --watch >/dev/null 2>&1 || true
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "hole that opened during the settle window was swallowed, log=$(cat "$log")"
pass "watch does not lose a hole that opens while it is settling"

# Two plonks must not compact concurrently: with the lock held, a run waits
# then skips cleanly (no dispatches), and runs normally once it is released.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
if command -v flock >/dev/null; then
  mkdir -p "$tmpdir/state-sandbox"
  mkdir -p "$tmpdir/state-sandbox"
  ( flock 9; sleep 1.2 ) 9<"$tmpdir/state-sandbox" &
  locker=$!
  sleep 0.1
  out=$(PLONK_LOCK_WAIT=0.3 run_plonk 2>&1) || fail "locked-out plonk must exit 0, got: $out"
  [[ $out == *"another plonk is compacting"* ]] || fail "expected the lock-skip message, got: $out"
  [[ -s $log ]] && fail "locked-out plonk must not dispatch anything, log=$(cat "$log")"
  wait "$locker"
  run_plonk >/dev/null
  grep -F 'change_id' "$log" >/dev/null || fail "plonk must compact normally after the lock is released"
  pass "concurrent plonks serialize on the state-dir lock"
  # A --watch daemon must release the lock between rounds, or every manual
  # plonk after its first compact is locked out forever.
  write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
  start_event_socket "$SOCK" $'destroyworkspace>>2\n'
  XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PATH="$stub:$PATH" \
    "$PLONK" --watch >/dev/null 2>&1 &
  watcher=$!
  sleep 1.2   # daemon has compacted once by now
  grep -F 'change_id' "$log" >/dev/null || fail "watch daemon did not compact in the lock-release test, log=$(cat "$log")"
  flock -n "$tmpdir/state-sandbox" -c true || fail "watch daemon keeps holding the lock between rounds"
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true
  pass "watch daemon releases the lock after each compact"
else
  pass "flock not present; lock test skipped"
fi

# --- an empty workspace a monitor is showing gets packed too ----------------
# Fred 2026-09-08: a second head sitting on an empty workspace 7 left the bar
# reading "1 2 3 7". It holds a number and every bar draws it, so it packs.
write_stub '{"id":1}' \
  '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}},{"name":"HEADLESS-8","activeWorkspace":{"id":7}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":7,"name":"7","monitor":"HEADLESS-8","windows":0,"ispersistent":false}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}}]'
out=$(run_plonk)
grep -F 'plonked workspace 7 -> 4' <<<"$out" >/dev/null || fail "a visible empty workspace must pack down, got: $out"
grep -F 'id = 4 })' "$log" >/dev/null || fail "it must be renumbered with change_id, got: $(cat "$log")"
grep -F 'window.move' "$log" >/dev/null && fail "an empty workspace has no windows to move"
pass "an empty workspace another monitor is showing packs down too"

# The move strategy cannot renumber it (no windows to carry), so it stays put
# and does not eat the number it would have taken.
: >"$log"
out=$(PLONK_RENUMBER=move run_plonk)
grep -F 'workspace 7' <<<"$out" >/dev/null && fail "move cannot renumber an empty workspace, got: $out"
grep -F 'Already Plonked' <<<"$out" >/dev/null || fail "nothing else should move, got: $out"
pass "the move strategy leaves an empty workspace where it is"

# A persistent workspace is configured to own its number.
write_stub '{"id":1}' \
  '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}},{"name":"HEADLESS-8","activeWorkspace":{"id":7}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":7,"name":"7","monitor":"HEADLESS-8","windows":0,"ispersistent":true}]' \
  '[{"address":"0xa","workspace":{"id":1}}]'
out=$(run_plonk)
grep -F 'Already Plonked' <<<"$out" >/dev/null || fail "a persistent workspace keeps its number, got: $out"
pass "a persistent empty workspace keeps its number"

# A reserved slot below a workspace must never push it UP the number line.
# Workspace 1 is LIVE but empty here — that is what still reserves a slot as of
# 1.2.4; a title on a workspace that no longer exists does not.
write_stub '{"id":2}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":2}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":0},{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":2}},{"address":"0xb","workspace":{"id":3}}]'
printf '%s\n' '{}' >"$track"
printf '%s\n' '{"1":"Reserved","2":"Two","3":"Three"}' >"$names"
out=$(WORKSPACE_NAMES_FILE="$names" run_plonk)
grep -F 'Already Plonked' <<<"$out" >/dev/null || fail "a reserved slot must not push workspaces up, got: $out"
[[ $(jq -cS . "$names") == '{"1":"Reserved","2":"Two","3":"Three"}' ]] || fail "titles must not move either, got: $(cat "$names")"
pass "a reserved slot never pushes a workspace up the number line"

# --- the empty workspace you opened stays where you put it -----------------
# Fred 2026-09-20: "allow one empty workspace to remain open if I open it."
# 1.2.2 packed every visible empty workspace, which meant SUPER+9 for a scratch
# space became workspace 4 with your focus dragged along behind it.
write_stub '{"id":9}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":9}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":3},{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":4},{"id":9,"name":"9","monitor":"eDP-1","windows":0,"ispersistent":false}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}}]'
out=$(run_plonk)
grep -F 'Already Plonked' <<<"$out" >/dev/null || fail "the workspace you opened must keep its number, got: $out"
[[ ! -s $log ]] || fail "nothing may be dispatched at all, got: $(cat "$log")"
pass "the empty workspace you opened keeps the number you chose"

# ...and your focus is never relocated off it either.
grep -F 'hl.dsp.focus' "$log" >/dev/null && fail "focus must not be moved off the workspace you opened"
pass "focus stays on the empty workspace you opened"

# Standing on an empty workspace BELOW an occupied one: the occupied one must
# not be renumbered onto it. change_id would fail on the taken id and the
# window-move fallback would merge those windows into the workspace you are
# looking at.
write_stub '{"id":2}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":2}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":3},{"id":2,"name":"2","monitor":"eDP-1","windows":0,"ispersistent":false},{"id":3,"name":"3","monitor":"eDP-1","windows":4}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xc","workspace":{"id":3}}]'
out=$(run_plonk)
grep -F 'window.move' "$log" >/dev/null && fail "windows must never be merged into the workspace you are standing on"
grep -F 'id = 2 })' "$log" >/dev/null && fail "nothing may be renumbered onto the workspace you are standing on"
pass "nothing lands on the empty workspace you are standing on"

# --- keep_open=one: hold ONE empty workspace open --------------------------
# Fred 2026-09-20, after 1.2.5 only stopped the RENUMBER: "still killing the
# new workspace I made." Hyprland drops an empty non-persistent workspace the
# moment focus leaves, so the scratch workspace evaporated on the way out.
held="$tmpdir/state-sandbox/held-workspace"
mkdir -p "$tmpdir/state-sandbox"
occupied_123='[{"id":1,"name":"1","monitor":"eDP-1","windows":3},{"id":2,"name":"2","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":4}'
clients_123='[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}}]'

# Standing on the empty workspace you opened: it gets pinned.
rm -f "$held"
write_stub '{"id":9}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":9}}]' \
  "$occupied_123,{\"id\":9,\"name\":\"9\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":false}]" "$clients_123"
out=$(PLONK_KEEP_OPEN=one run_plonk)
grep -F 'persistent = true' "$log" >/dev/null || fail "the workspace you opened must be pinned, got: $(cat "$log")"
grep -F 'workspace = "9"' "$log" >/dev/null || fail "the pin must name workspace 9, got: $(cat "$log")"
[[ $(cat "$held" 2>/dev/null) == 9 ]] || fail "the held workspace must be recorded, got: $(cat "$held" 2>/dev/null)"
pass "keep_open=one pins the empty workspace you opened"

# THE BUG: you walk away and it must still be there. Held, still empty, you are
# now on an occupied workspace -> nothing is released.
printf '9\n' >"$held"
write_stub '{"id":1}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}}]' \
  "$occupied_123,{\"id\":9,\"name\":\"9\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":true}]" "$clients_123"
out=$(PLONK_KEEP_OPEN=one run_plonk)
grep -F 'persistent = false' "$log" >/dev/null && fail "leaving it must NOT release it, got: $(cat "$log")"
[[ $(cat "$held" 2>/dev/null) == 9 ]] || fail "it must still be held after you leave, got: $(cat "$held" 2>/dev/null)"
pass "the held workspace survives you leaving it"

# Used: it has windows now, so it is a normal workspace and the pin goes.
printf '9\n' >"$held"
write_stub '{"id":1}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}}]' \
  "$occupied_123,{\"id\":9,\"name\":\"9\",\"monitor\":\"eDP-1\",\"windows\":1,\"ispersistent\":true}]" \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}},{"address":"0xd","workspace":{"id":9}}]'
out=$(PLONK_KEEP_OPEN=one run_plonk)
grep -F 'persistent = false' "$log" >/dev/null || fail "a used workspace must be released, got: $(cat "$log")"
[[ ! -s $held ]] || fail "the held record must be cleared once used, got: $(cat "$held" 2>/dev/null)"
pass "the held workspace is released once you put something in it"

# Replaced: you open a different empty one, so the pin moves. Only ever one.
printf '9\n' >"$held"
write_stub '{"id":5}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":5}}]' \
  "$occupied_123,{\"id\":5,\"name\":\"5\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":false},{\"id\":9,\"name\":\"9\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":true}]" "$clients_123"
out=$(PLONK_KEEP_OPEN=one run_plonk)
grep -F 'persistent = false' "$log" >/dev/null || fail "the old hold must be released, got: $(cat "$log")"
grep -E 'workspace = "5".*persistent = true' "$log" >/dev/null || fail "the new one must be pinned, got: $(cat "$log")"
[[ $(cat "$held" 2>/dev/null) == 5 ]] || fail "only one is held at a time, got: $(cat "$held" 2>/dev/null)"
pass "opening another empty workspace moves the hold, never keeps two"

# Default off: the published behaviour is untouched, nothing is ever pinned.
rm -f "$held"
write_stub '{"id":9}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":9}}]' \
  "$occupied_123,{\"id\":9,\"name\":\"9\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":false}]" "$clients_123"
out=$(run_plonk)
grep -F 'persistent' "$log" >/dev/null && fail "keep_open is opt-in; default must pin nothing, got: $(cat "$log")"
[[ ! -e $held ]] || fail "default must record no hold"
pass "keep_open defaults to off and pins nothing"

# A workspace YOU made persistent in your Hyprland config is not plonk's.
rm -f "$held"
write_stub '{"id":7}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":7}}]' \
  "$occupied_123,{\"id\":7,\"name\":\"7\",\"monitor\":\"eDP-1\",\"windows\":0,\"ispersistent\":true}]" "$clients_123"
out=$(PLONK_KEEP_OPEN=one run_plonk)
grep -F 'persistent' "$log" >/dev/null && fail "a config-persistent workspace must be left alone, got: $(cat "$log")"
[[ ! -e $held ]] || fail "a config-persistent workspace must not be recorded as held"
pass "a workspace persistent from your own config is never touched"

# --- rescue_stranded: a floating window that is wholly off every monitor ----
# Fred 2026-10-18: "Workspace two is empty and it is not clearing." It was not
# empty. It held a floating window at (-2619,-3104) on a monitor that sits at
# (0,-720) — a position left over from a layout that no longer exists. Hyprland
# counts the window, plonk correctly leaves an occupied workspace alone, and the
# user stares at a blank screen.
mkwin() { # address class workspace floating x y w h [hidden]
  printf '{"address":"%s","class":"%s","workspace":{"id":%s},"floating":%s,"mapped":true,"hidden":%s,"fullscreen":0,"at":[%s,%s],"size":[%s,%s]}' \
    "$1" "$2" "$3" "$4" "${9:-false}" "$5" "$6" "$7" "$8"
}
DP3='[{"name":"DP-3","focused":true,"x":0,"y":-720,"width":5120,"height":2160,"scale":1,"transform":0,"activeWorkspace":{"id":1}}]'
WS12='[{"id":1,"name":"1","monitor":"DP-3","windows":1},{"id":2,"name":"2","monitor":"DP-3","windows":1}]'
tiled=$(mkwin 0xaa kitty 1 false 10 20 800 600)
stranded=$(mkwin 0xdead grok-bot 2 true -2619 -3104 2758 2009)

# Off by default: the published behaviour is untouched.
write_stub '{"id":1}' "$DP3" "$WS12" "[$tiled,$stranded]"
out=$(run_plonk)
grep -E 'window\.(resize|move)' "$log" >/dev/null && fail "rescue_stranded is opt-in; default must move nothing, got: $(cat "$log")"
pass "rescue_stranded defaults to off and moves nothing"

# On: resize first, then move, absolute, centred on the monitor's REAL origin.
# 5120x2160 at (0,-720): width stays 2758, height is capped at 80% = 1728,
# x = (5120-2758)/2 = 1181, y = -720 + (2160-1728)/2 = -504.
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -F 'rescued' <<<"$out" >/dev/null || fail "the rescue must be reported, got: $out"
r=$(grep -n 'hl.dsp.window.resize({ x = 2758, y = 1728, relative = false, window = "address:0xdead" })' "$log" | cut -d: -f1)
m=$(grep -n 'hl.dsp.window.move({ x = 1181, y = -504, relative = false, window = "address:0xdead" })' "$log" | cut -d: -f1)
[[ -n $r && -n $m ]] || fail "expected an absolute resize and move to 2758x1728 at 1181,-504, got: $(cat "$log")"
((r < m)) || fail "resize must come BEFORE move so the window never overhangs its new home, got: $(cat "$log")"
grep -F 'address:0xaa' "$log" >/dev/null && fail "the visible tiled window must not be touched, got: $(cat "$log")"
pass "a stranded floating window is resized then moved, centred on the monitor's real origin"

# --dry-run plans it and dispatches nothing.
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk --dry-run)
grep -F "would rescue 'grok-bot' on workspace 2 -> 2758x1728 at 1181,-504" <<<"$out" >/dev/null || fail "dry run must plan the rescue, got: $out"
grep -E 'window\.(resize|move)' "$log" >/dev/null && fail "dry run must dispatch nothing, got: $(cat "$log")"
pass "--dry-run plans the rescue without moving anything"

# Things that are NOT stranded must be left strictly alone.
partly=$(mkwin 0xb1 kitty 2 true -100 100 400 300)              # 300px of it is on screen
tile_off=$(mkwin 0xb2 kitty 2 false -9000 -9000 400 300)        # tiled: the layout owns it
special=$(mkwin 0xb3 quake -98 true -9000 -9000 400 300)        # special workspace: parked off-screen on purpose
hid=$(mkwin 0xb4 kitty 2 true -9000 -9000 400 300 true)         # hidden
write_stub '{"id":1}' "$DP3" "$WS12" "[$tiled,$partly,$tile_off,$special,$hid]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -E 'window\.(resize|move)' "$log" >/dev/null && fail "only floating, mapped, visible-nowhere windows on a numbered workspace qualify, got: $(cat "$log")"
pass "partly visible, tiled, special-workspace and hidden windows are never rescued"

# A window with no usable address must never reach a dispatch: an empty address
# silently targets the ACTIVE window.
noaddr=$(mkwin "" grok-bot 2 true -2619 -3104 2758 2009)
badaddr=$(mkwin "0xZZ" grok-bot 2 true -2619 -3104 2758 2009)
write_stub '{"id":1}' "$DP3" "$WS12" "[$tiled,$noaddr,$badaddr]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -E 'window\.(resize|move)' "$log" >/dev/null && fail "a missing or malformed address must never be dispatched at, got: $(cat "$log")"
pass "a window with an empty or malformed address is never dispatched at"

# No monitor information at all: there is nothing to compare against.
write_stub '{"id":1}' '[]' "$WS12" "[$tiled,$stranded]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -E 'window\.(resize|move)' "$log" >/dev/null && fail "with no monitors known, nothing may be moved, got: $(cat "$log")"
pass "no monitor information means no rescue"

# Scale: geometry is logical. 3840x2400 at scale 2 is a 1920x1200 desktop.
HIDPI='[{"name":"eDP-1","focused":true,"x":0,"y":0,"width":3840,"height":2400,"scale":2,"transform":0,"activeWorkspace":{"id":1}}]'
WS12E='[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"eDP-1","windows":1}]'
big=$(mkwin 0xc1 kitty 2 true -5000 -5000 3000 2000)
write_stub '{"id":1}' "$HIDPI" "$WS12E" "[$tiled,$big]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -F 'resize({ x = 1536, y = 960,' "$log" >/dev/null || fail "a scale-2 monitor is 1920x1200 logical, 80% is 1536x960, got: $(cat "$log")"
grep -F 'move({ x = 192, y = 120,' "$log" >/dev/null || fail "centred in logical coordinates, got: $(cat "$log")"
pass "rescue geometry is logical (scale-adjusted)"

# Rotation: a 90 degree transform swaps width and height.
TURNED='[{"name":"eDP-1","focused":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1,"transform":1,"activeWorkspace":{"id":1}}]'
small=$(mkwin 0xc2 kitty 2 true -5000 -5000 500 400)
write_stub '{"id":1}' "$TURNED" "$WS12E" "[$tiled,$small]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -F 'move({ x = 290, y = 760,' "$log" >/dev/null || fail "a rotated 1920x1080 is 1080x1920; 500x400 centres at 290,760, got: $(cat "$log")"
pass "rescue geometry follows a rotated monitor"

# Two monitors: it goes home — the monitor its workspace lives on.
TWOMON='[{"name":"A","focused":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1,"transform":0,"activeWorkspace":{"id":1}},{"name":"B","focused":false,"x":1920,"y":0,"width":1920,"height":1080,"scale":1,"transform":0,"activeWorkspace":{"id":5}}]'
WSAB='[{"id":1,"name":"1","monitor":"A","windows":1},{"id":5,"name":"5","monitor":"B","windows":2}]'
onb=$(mkwin 0xd1 kitty 5 true 2100 100 600 400)                  # fine, on monitor B
lost=$(mkwin 0xd2 kitty 5 true -9000 -9000 600 400)
write_stub '{"id":1}' "$TWOMON" "$WSAB" "[$tiled,$onb,$lost]"
: >"$log"
out=$(PLONK_RESCUE_STRANDED=on run_plonk)
grep -F 'address:0xd1' "$log" >/dev/null && fail "a window sitting on monitor B is not stranded, got: $(cat "$log")"
grep -F 'move({ x = 2580, y = 340, relative = false, window = "address:0xd2" })' "$log" >/dev/null ||
  fail "it must land on its workspace's monitor (B), centred at 2580,340, got: $(cat "$log")"
pass "a stranded window goes to the monitor its workspace lives on"

# --- watch: the daemon rescues on an ordinary event, and gives up cleanly -----
# Stranding happens silently (Hyprland sends no event when a monitor goes), so
# the rescue has to ride the rounds that ordinary events already start.
write_stub '{"id":1}' "$DP3" "$WS12" "[$tiled]"
printf '%s\n' "[$tiled]" >"$tmpdir/clients.json"
printf '%s\n' "[$tiled,$stranded]" >"$tmpdir/clients-lost.json"
sed -i "s|clients) printf .*|clients) cat '$tmpdir/clients.json' ;;|" "$stub/hyprctl"
cat >"$tmpdir/strand-late.sh" <<GEN
exec 2>/dev/null
sleep 0.6
cp '$tmpdir/clients-lost.json' '$tmpdir/clients.json'
echo 'openwindow>>0xee,2,kitty,kitty'
sleep 1
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/strand-late.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_RESCUE_STRANDED=on \
  PATH="$stub:$PATH" timeout 3 "$PLONK" --watch >/dev/null 2>"$tmpdir/watch.err" || true
grep -F 'window = "address:0xdead"' "$log" >/dev/null || fail "the daemon must rescue on an ordinary event, log=$(cat "$log")"
grep -F "rescued 'grok-bot' stranded off-screen on workspace 2" "$tmpdir/watch.err" >/dev/null ||
  fail "the daemon must say so on stderr, got: $(cat "$tmpdir/watch.err")"
pass "watch rescues a stranded window on the next ordinary event, and says so"

# A window that will not move is given up on: five tries, one warning, no loop.
write_stub '{"id":1}' "$DP3" "$WS12" "[$tiled,$stranded]"
cat >"$tmpdir/many-events.sh" <<GEN
exec 2>/dev/null
for i in 1 2 3 4 5 6 7 8; do sleep 0.45; echo 'openwindow>>0xee,2,kitty,kitty'; done
sleep 0.5
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/many-events.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_RESCUE_STRANDED=on \
  PATH="$stub:$PATH" timeout 7 "$PLONK" --watch >/dev/null 2>"$tmpdir/watch.err" || true
n=$(grep -c 'window.resize' "$log" || true)
[[ $n == 5 ]] || fail "a window that will not move gets exactly 5 tries, got $n: $(cat "$log")"
[[ $(grep -c 'cannot bring' "$tmpdir/watch.err") == 1 ]] || fail "it must give up once, loudly, got: $(cat "$tmpdir/watch.err")"
pass "a window that will not move is given up on after five tries, once, loudly"

# --- multi-monitor: the other head's empty active workspace is not a hole --
# HDMI-1 (unfocused) is showing empty workspace 2; eDP-1 (focused, active 1)
# has 1 and 4 occupied. 4 must go to 3, never be merged into HDMI's 2.
write_stub '{"id":1}' \
  '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}},{"name":"HDMI-1","focused":false,"activeWorkspace":{"id":2}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"HDMI-1","windows":0},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xd","workspace":{"id":4}}]'
run_plonk >/dev/null
grep -F 'workspace = "2"' "$log" >/dev/null && fail "must not land on the workspace another monitor is showing, log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "4", id = 3 })' "$log" >/dev/null || fail "4 -> 3 around the other head's empty workspace, log=$(cat "$log")"
pass "never fills the empty workspace another monitor is displaying"

# --- watch: a stale pause is checked against hyprctl layers --------------
# openlayer with no matching closelayer, then a real hole. With no hyprshell
# layer actually present the watcher must unpause and compact.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'openlayer>>hyprshell_switch\ndestroyworkspace>>2\n'
STUB_LAYERS='{"eDP-1":{"levels":{"1":[{"namespace":"omarchy-bar"}]}}}' run_watch_once >/dev/null
grep -F 'change_id' "$log" >/dev/null || fail "stale pause must not block compaction when the overlay is gone, log=$(cat "$log")"
pass "watch recovers from a stuck pause when the overlay layer is gone"
# ...and stays paused while the overlay really is up.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
start_event_socket "$SOCK" $'openlayer>>hyprshell_switch\ndestroyworkspace>>2\n'
STUB_LAYERS='{"eDP-1":{"levels":{"2":[{"namespace":"hyprshell_switch"}]}}}' run_watch_once >/dev/null
grep -F 'change_id' "$log" >/dev/null && fail "must stay paused while the overlay layer exists, log=$(cat "$log")"
pass "watch stays paused while the overlay layer is really open"

# --- no HOME and no state vars at all: still compacts, titles still travel --
# (#1 made NAMES_FILE HOME-free; the lock/backup/notify paths crashed with
# "HOME: unbound variable" under set -u — silently swallowed in watch mode.)
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
printf '%s\n' '{"3":"Ride"}' >"$tmpdir/nohome-names.json"
env -u HOME -u PLONK_STATE_DIR -u XDG_STATE_HOME -u XDG_CONFIG_HOME \
  WORKSPACE_NAMES_FILE="$tmpdir/nohome-names.json" PATH="$stub:$PATH" "$PLONK" >/dev/null 2>"$tmpdir/nohome.err" ||
  fail "plonk must run without HOME/state vars, stderr: $(cat "$tmpdir/nohome.err")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null || fail "no-HOME run still compacts, log=$(cat "$log")"
[[ $(jq -r '."2"' "$tmpdir/nohome-names.json") == Ride ]] || fail "no-HOME run still carries the title, got: $(cat "$tmpdir/nohome-names.json")"
pass "runs, compacts and remaps titles with no HOME and no state directory"

# --- corrupt names file: compact anyway, but warn ----------------------------
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
printf '%s' '{"3":"Ride"' >"$tmpdir/broken-names.json"
err=$(WORKSPACE_NAMES_FILE="$tmpdir/broken-names.json" run_plonk 2>&1 >/dev/null) || fail "corrupt names file must not abort the compact"
grep -F 'change_id' "$log" >/dev/null || fail "still compacts with a corrupt names file"
[[ $err == *"cannot parse"* ]] || fail "must warn about the unreadable names file, stderr: $err"
[[ $(grep -c 'cannot parse' <<<"$err") == 1 ]] || fail "warn once per compact, got: $err"
[[ $(cat "$tmpdir/broken-names.json") == '{"3":"Ride"' ]] || fail "never rewrites a file it cannot parse"
pass "corrupt names file: compacts, warns once, leaves the file alone"

# --- watch: stale HYPRLAND_INSTANCE_SIGNATURE follows the discovered socket --
# The daemon outlives a Hyprland restart: env still says the old instance,
# the socket lives under the new one. hyprctl must be pointed at the new one.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
rm -rf "$tmpdir/hypr/stale-old"
NEWSOCK="$tmpdir/hypr/fresh-instance/.socket2.sock"
start_event_socket "$NEWSOCK" $'destroyworkspace>>2\n'
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=stale-old EXPECT_SIG=fresh-instance \
  PATH="$stub:$PATH" timeout 3 "$PLONK" --watch >/dev/null 2>"$tmpdir/sig.err" || true
grep -F 'change_id' "$log" >/dev/null || fail "hyprctl must follow the discovered instance, stderr: $(cat "$tmpdir/sig.err")"
pass "watch re-points hyprctl at the Hyprland instance it found"
rm -rf "$tmpdir/hypr/fresh-instance"

# --- watch: a window opening above a gap is a hole ---------------------------
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
# (the connect-time compact would mask this; give it an already-compact
#  view first, then swap in the hole before the openwindow event)
printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' >"$tmpdir/ws.json"
printf '%s\n' "$HOLE_GONE" >"$tmpdir/ws-hole.json"
sed -i "s|workspaces) printf .*|workspaces) cat '$tmpdir/ws.json' ;;|" "$stub/hyprctl"
cat >"$tmpdir/open-late.sh" <<GEN
exec 2>/dev/null
sleep 0.6
cp '$tmpdir/ws-hole.json' '$tmpdir/ws.json'
echo 'openwindow>>0xc,4,kitty,kitty'
sleep 1
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/open-late.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
run_watch_once >/dev/null
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "openwindow above a gap must trigger a compact, log=$(cat "$log")"
pass "watch compacts when a window opens above a gap"

# --- watch: the daemon keeps its stderr after the first round -----------------
# compact() used to end with `exec 9>&- 2>/dev/null`. A bare exec applies BOTH
# redirections to the whole shell, so after the first round the daemon's stderr
# was /dev/null for good and every message it printed vanished (the journal
# stayed empty for weeks). Every other watcher test throws stderr away, which is
# why nothing caught it. This one reads it, and the message that matters comes
# from the SECOND round, after the old line had already run.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' >"$tmpdir/ws.json"
printf '%s\n' "$HOLE_GONE" >"$tmpdir/ws-hole.json"
sed -i "s|workspaces) printf .*|workspaces) cat '$tmpdir/ws.json' ;;|" "$stub/hyprctl"
cat >"$tmpdir/second-round.sh" <<GEN
exec 2>/dev/null
sleep 0.6
cp '$tmpdir/ws-hole.json' '$tmpdir/ws.json'
echo 'openwindow>>0xc,4,kitty,kitty'
sleep 1
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/second-round.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig \
  PATH="$stub:$PATH" timeout 3 "$PLONK" --watch >/dev/null 2>"$tmpdir/watch.err" || true
grep -F 'plonked workspace 3 -> 2' "$tmpdir/watch.err" >/dev/null ||
  fail "the daemon's second round must still be able to print to stderr, got: $(cat "$tmpdir/watch.err")"
pass "watch keeps its stderr after the first round"

# --- watch: creating a workspace wakes the daemon ---------------------------
# THE bug behind "still killing the new workspace I made": the watcher listened
# for destroyworkspace but never createworkspace, so making a workspace woke
# plonk not at all and keep_open never got its chance to pin it.
write_stub '{"id":9}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":9}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' '[{"address":"0xa","workspace":{"id":1}}]'
printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]' >"$tmpdir/ws.json"
printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":9,"name":"9","monitor":"eDP-1","windows":0,"ispersistent":false}]' >"$tmpdir/ws-new.json"
sed -i "s|workspaces) printf .*|workspaces) cat '$tmpdir/ws.json' ;;|" "$stub/hyprctl"
cat >"$tmpdir/create-late.sh" <<GEN
exec 2>/dev/null
sleep 0.6
cp '$tmpdir/ws-new.json' '$tmpdir/ws.json'
echo 'createworkspace>>9'
sleep 1
GEN
rm -f "$SOCK" "$tmpdir/state-sandbox/held-workspace"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/create-late.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
PLONK_KEEP_OPEN=one run_watch_once >/dev/null
grep -F 'persistent = true' "$log" >/dev/null ||
  fail "createworkspace must wake the watcher so the new workspace is pinned, log=$(cat "$log")"
pass "watch pins the workspace you just created"

# --- watch: compacts once on connect, with no events at all ------------------
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
start_event_socket "$SOCK" ''
run_watch_once >/dev/null
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "pre-existing hole must be closed on connect, log=$(cat "$log")"
pass "watch closes pre-existing holes when it connects"

# A trigger received after the connect-time settle must compact immediately,
# not sit through another full pre-compact settle. With a deliberately huge
# 900 ms settle, the old watcher missed this 1.45 s deadline.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$COMPACT_WS" "$HOLE_CLIENTS"
printf '%s\n' "$COMPACT_WS" >"$tmpdir/ws.json"
printf '%s\n' "$HOLE_GONE" >"$tmpdir/ws-hole.json"
sed -i "s|workspaces) printf .*|workspaces) cat '$tmpdir/ws.json' ;;|" "$stub/hyprctl"
cat >"$tmpdir/immediate-trigger.sh" <<GEN
exec 2>/dev/null
sleep 1
cp '$tmpdir/ws-hole.json' '$tmpdir/ws.json'
echo 'moveworkspacev2>>3,3,eDP-1'
sleep 1
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/immediate-trigger.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_SETTLE_US=900000 \
  PATH="$stub:$PATH" timeout 1.45 "$PLONK" --watch >/dev/null 2>&1 || true
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "watch must compact before a second pre-settle budget elapses, log=$(cat "$log")"
pass "watch compacts first and settles afterward"

# The window-move fallback emits movewindow + moveworkspace + destroyworkspace
# events of its own. They must be swallowed rather than causing a redundant
# no-op round. Real socket2 events carry window addresses WITHOUT the 0x that
# `hyprctl clients -j` prints (verified live on Hyprland 0.56.2), so the
# fixture uses the bare form: a filter keyed on "0xa" never matches anything.
active_file="$tmpdir/self-event-active.json"
active_calls="$tmpdir/self-event-active.calls"
printf '%s\n' '{"id":1}' >"$active_file"
printf '0\n' >"$active_calls"
printf '%s\n' "$COMPACT_WS" >"$tmpdir/ws.json"
printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":0},{"id":3,"name":"3","monitor":"eDP-1","windows":1}]' >"$tmpdir/ws-fallback.json"
cat >"$stub/hyprctl" <<STUB
#!/bin/bash
case "\$1" in
  activeworkspace) n=\$(cat "$active_calls"); printf '%s\n' "\$((n + 1))" >"$active_calls"; cat "$active_file" ;;
  monitors) printf '%s\n' '[{"name":"eDP-1"}]' ;;
  workspaces) cat "$tmpdir/ws.json" ;;
  clients) printf '%s\n' '[{"address":"0xa","workspace":{"id":3}}]' ;;
  layers) printf '%s\n' '{}' ;;
  dispatch) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  eval) printf '%s\n' "\$*" >>"$log"; echo ok ;;
  *) echo "unexpected hyprctl \$1" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/hyprctl"
: >"$log"
cat >"$tmpdir/self-events.sh" <<GEN
exec 2>/dev/null
sleep 0.3
printf '%s\n' '{"id":3}' >'$active_file'
cp '$tmpdir/ws-fallback.json' '$tmpdir/ws.json'
echo 'destroyworkspace>>2'
sleep 0.06
echo 'movewindow>>a,1'
echo 'movewindowv2>>a,1,1'
echo 'moveworkspacev2>>1,1,eDP-1'
echo 'destroyworkspace>>3'
echo 'destroyworkspacev2>>3,3'
sleep 0.5
GEN
rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/self-events.sh'" &
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_SETTLE_US=100000 \
  PATH="$stub:$PATH" timeout 1.1 "$PLONK" --watch >/dev/null 2>&1 || true
[[ $(grep -c 'hl.dsp.window.move' "$log") == 1 ]] || fail "own fallback events caused another move round, log=$(cat "$log")"
[[ $(cat "$active_calls") == 5 ]] || fail "own fallback events caused another snapshot, active calls=$(cat "$active_calls"), log=$(cat "$log")"
pass "watch ignores the fallback events it emits itself"

# If a manual plonk owns the lock, the watcher must retain its pending round
# and retry after the lock is released even when no second event arrives.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$HOLE_GONE" "$HOLE_CLIENTS"
start_event_socket "$SOCK" ''
mkdir -p "$tmpdir/state-sandbox"
( flock 9; sleep 0.18 ) 9<"$tmpdir/state-sandbox" &
locker=$!
sleep 0.02
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_LOCK_WAIT=0.02 PLONK_SETTLE_US=50000 \
  PATH="$stub:$PATH" timeout 1 "$PLONK" --watch >/dev/null 2>&1 || true
wait "$locker" 2>/dev/null || true
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null ||
  fail "watch dropped its round while the lock was busy, log=$(cat "$log")"
pass "watch retries a compact skipped by the lock"

# --- watch: a script replaced underneath the daemon takes effect -------------
# Fred 2026-09-10: vic's watcher had been up since Sep 5 while the script was
# rewritten on Sep 8, so the box ran 1.1.2 logic with 1.2.2 on disk and every
# fix in between was inert. bash keeps what it already parsed, so the daemon
# has to notice and re-exec itself.
live="$tmpdir/plonk-live"
marker="$tmpdir/reexec.marker"
cp "$PLONK" "$live"; chmod +x "$live"
rm -f "$marker"
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$COMPACT_WS" "$HOLE_CLIENTS"
rm -f "$SOCK"
cat >"$tmpdir/reexec-feed.sh" <<'GEN'
exec 2>/dev/null
sleep 0.6
printf '%s\n' 'openwindow>>a'
sleep 1.2
GEN
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sh '$tmpdir/reexec-feed.sh'" &
feeder=$!
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_SETTLE_US=50000 \
  PATH="$stub:$PATH" timeout 3 "$live" --watch >/dev/null 2>&1 &
daemon=$!
sleep 0.3
# Replace atomically, the way an install or a git checkout does. Writing over
# the file in place would truncate it under the running bash, which reads its
# own script by offset and simply dies — the hazard this guard exists for, and
# one no in-process check can survive.
cat >"$live.new" <<GEN
#!/usr/bin/env bash
printf 'replaced\n' > "$marker"
sleep 2
GEN
chmod +x "$live.new"
mv "$live.new" "$live"
wait "$daemon" 2>/dev/null || true
kill "$feeder" 2>/dev/null || true
wait "$feeder" 2>/dev/null || true
[[ -f $marker ]] || fail "a script replaced under the watcher must be re-exec'd"
pass "the watcher re-execs when its own script is updated"

# --- watch: stopping the daemon takes its socat reader down with it ----------
# The plugin service (and systemctl stop) SIGTERM the daemon. bash dies, but
# the process-substitution socat kept its connection to Hyprland until the
# next event hit its dead pipe. The listener here stays open and silent, so a
# leaked reader would still be sitting on the socket when we look.
write_stub '{"id":1}' '[{"name":"eDP-1"}]' "$COMPACT_WS" "$HOLE_CLIENTS"
mkdir -p "$(dirname "$SOCK")"; rm -f "$SOCK"
socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sleep 4" &
listener=$!
for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_SETTLE_US=50000 \
  PATH="$stub:$PATH" "$PLONK" --watch >/dev/null 2>&1 &
daemon=$!
for _ in $(seq 1 40); do pgrep -f "UNIX-CONNECT:$SOCK" >/dev/null && break; sleep 0.05; done
pgrep -f "UNIX-CONNECT:$SOCK" >/dev/null || fail "daemon never connected its socat reader"
kill -TERM "$daemon"
wait "$daemon" 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -f "UNIX-CONNECT:$SOCK" >/dev/null || break; sleep 0.05; done
if pgrep -f "UNIX-CONNECT:$SOCK" >/dev/null; then
  pkill -f "UNIX-CONNECT:$SOCK" || true
  kill "$listener" 2>/dev/null || true
  fail "socat reader leaked after the daemon was stopped"
fi
kill "$listener" 2>/dev/null || true
wait "$listener" 2>/dev/null || true
pass "stopping the watcher kills its socat reader"

# ...and dies OF the signal rather than exiting 143: systemd marks a unit
# that exits with code 143 after `systemctl stop` as failed, while a SIGTERM
# death is a clean stop. bash's $? cannot tell the two apart; waitpid can.
if command -v python3 >/dev/null; then
  rm -f "$SOCK"
  socat UNIX-LISTEN:"$SOCK",unlink-early SYSTEM:"sleep 4" &
  listener=$!
  for _ in $(seq 1 40); do [[ -S $SOCK ]] && break; sleep 0.05; done
  how=$(XDG_RUNTIME_DIR="$tmpdir" HYPRLAND_INSTANCE_SIGNATURE=watchsig PLONK_SETTLE_US=50000 \
    PATH="$stub:$PATH" python3 -c '
import signal, subprocess, sys, time
p = subprocess.Popen([sys.argv[1], "--watch"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.6)
p.send_signal(signal.SIGTERM)
rc = p.wait(timeout=3)
print("signal" if rc < 0 else "exit %d" % rc)
' "$PLONK")
  pkill -f "UNIX-CONNECT:$SOCK" 2>/dev/null || true
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
  [[ $how == signal ]] || fail "watcher must die of SIGTERM (clean stop), got: $how"
  pass "stopped watcher dies of SIGTERM, not exit 143"
fi

# Archive vanished named slots only when explicitly configured. Reproduce the
# live failure: workspace 5 is gone but its title blocks 6 from closing the gap.
archive_names="$tmpdir/archive-names.json"
archive_fixture='{"_config":{"pill":true},"1":"Brave","2":"Tesla","3":"Voice","4":"Fixes","5":"Update vic","6":"Screen Saver"}'
write_stub '{"id":6}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":6}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":3,"name":"3","monitor":"eDP-1","windows":1},{"id":4,"name":"4","monitor":"eDP-1","windows":1},{"id":6,"name":"6","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":3}},{"address":"0xc","workspace":{"id":4}},{"address":"0xd","workspace":{"id":6}}]'
printf '%s\n' "$archive_fixture" > "$archive_names"
out=$(PLONK_EMPTY_NAMES=archive WORKSPACE_NAMES_FILE="$archive_names" run_plonk --dry-run)
[[ $out == *'workspace 6 -> 4'* ]] || fail "archive dry-run should close all gaps: $out"
[[ $(cat "$archive_names") == "$archive_fixture" && ! -s $log ]] || fail "archive dry-run must not write or dispatch"
PLONK_EMPTY_NAMES=archive WORKSPACE_NAMES_FILE="$archive_names" run_plonk >/dev/null
jq -e '."1" == "Brave" and ."2" == "Voice" and ."3" == "Fixes" and ."4" == "Screen Saver"
  and (has("5") | not) and (has("6") | not) and ._config.pill
  and (._plonk_archived_names | map(.name) | sort) == ["Tesla","Update vic"]' "$archive_names" >/dev/null || fail "occupied names travel and vanished names remain archived: $(cat "$archive_names")"
pass "archive mode releases ghost slots, preserves names, and dry-run is read-only"

write_stub '{"id":1}' '[{"name":"eDP-1","focused":true,"activeWorkspace":{"id":1}},{"name":"HDMI-1","activeWorkspace":{"id":2}}]' \
  '[{"id":1,"name":"1","monitor":"eDP-1","windows":1},{"id":2,"name":"2","monitor":"HDMI-1","windows":0},{"id":4,"name":"4","monitor":"eDP-1","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":4}}]'
printf '%s\n' '{"2":"Other monitor","4":"Work"}' > "$archive_names"
PLONK_EMPTY_NAMES=archive WORKSPACE_NAMES_FILE="$archive_names" run_plonk >/dev/null
jq -e '."2" == "Other monitor" and ."3" == "Work" and (has("_plonk_archived_names") | not)' "$archive_names" >/dev/null || fail "archive mode must preserve a live empty workspace"
printf '%s\n' '{"2":"Other monitor","4":"Work","_plonk_archived_names":"damaged"}' > "$archive_names"
cp "$archive_names" "$tmpdir/archive-before.json"
: > "$log"
if PLONK_EMPTY_NAMES=archive WORKSPACE_NAMES_FILE="$archive_names" run_plonk >/dev/null 2>&1; then fail "damaged archive must reject compaction"; fi
cmp "$archive_names" "$tmpdir/archive-before.json" || fail "damaged archive must stay untouched"
[[ ! -s $log ]] || fail "damaged archive must not move windows"
pass "archive mode protects live empty workspaces and damaged archives"

# --- group_monitors: each monitor's workspaces stay together ----------------
# Fred's real layout 2026-10-18: LG (x=0) has 1,2,4; Samsung (x=5120) has 3.
# Grouped, LG takes 1-3 and Samsung 4: workspaces 3 and 4 trade places, which
# needs a spare number because change_id refuses a taken id.
GM_MON='[{"name":"HDMI-A-1","x":5120,"y":0,"focused":false,"activeWorkspace":{"id":3}},{"name":"DP-3","x":0,"y":-720,"focused":true,"activeWorkspace":{"id":4}}]'
GM_WS='[{"id":1,"name":"1","monitor":"DP-3","windows":1},{"id":2,"name":"2","monitor":"DP-3","windows":1},{"id":3,"name":"3","monitor":"HDMI-A-1","windows":1},{"id":4,"name":"4","monitor":"DP-3","windows":1}]'
GM_CL='[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}},{"address":"0xd","workspace":{"id":4}}]'
write_stub '{"id":4}' "$GM_MON" "$GM_WS" "$GM_CL"
out=$(run_plonk)
[[ $out == "plonk: Already Plonked!" ]] || fail "group_monitors defaults to off, got: $out"
[[ ! -s $log ]] || fail "off must dispatch nothing, log=$(cat "$log")"
out=$(PLONK_GROUP_MONITORS=on run_plonk --dry-run)
grep -Fx 'would plonk workspace 4 -> 3 (DP-3)' <<<"$out" >/dev/null || fail "grouped dry-run plan 4 -> 3, got: $out"
grep -Fx 'would plonk workspace 3 -> 4 (HDMI-A-1)' <<<"$out" >/dev/null || fail "grouped dry-run plan 3 -> 4, got: $out"
[[ ! -s $log ]] || fail "grouped dry-run must dispatch nothing"
out=$(PLONK_GROUP_MONITORS=on run_plonk)
mapfile -t cid < <(grep -o 'workspace = "[0-9]*", id = [0-9]*' "$log" | tr -d '",=' | awk '{print $2"->"$4}')
[[ ${cid[*]} == "4->101 3->4 101->3" ]] || fail "swap goes through a spare, got: ${cid[*]}"
grep -Fx 'plonked workspace 3 -> 4 (HDMI-A-1)' <<<"$out" >/dev/null || fail "reports the real swap, got: $out"
grep -Fx 'plonked workspace 4 -> 3 (DP-3)' <<<"$out" >/dev/null || fail "reports the hop as one move, got: $out"
grep -F '101' <<<"$out" >/dev/null && fail "the spare number is never reported, got: $out"
grep -Fx 'dispatch hl.dsp.focus({ workspace = "3" })' "$log" >/dev/null || fail "focus follows the focused monitor's workspace 4 to 3, log=$(cat "$log")"
pass "group_monitors: a swap between monitors hops through a spare, once"

# No swap: B(x=100) lists first but sits right of A. A has 1,5; B has 2.
# Grouped: A 1,2 and B 3. B's 2 must clear to 3 BEFORE A's 5 lands on 2.
write_stub '{"id":1}' \
  '[{"name":"B","x":100,"y":0,"activeWorkspace":{"id":2}},{"name":"A","x":0,"y":0,"focused":true,"activeWorkspace":{"id":1}}]' \
  '[{"id":1,"name":"1","monitor":"A","windows":1},{"id":2,"name":"2","monitor":"B","windows":1},{"id":5,"name":"5","monitor":"A","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":5}}]'
PLONK_GROUP_MONITORS=on run_plonk >/dev/null
mapfile -t cid < <(grep -o 'workspace = "[0-9]*", id = [0-9]*' "$log" | tr -d '",=' | awk '{print $2"->"$4}')
[[ ${cid[*]} == "2->3 5->2" ]] || fail "orders by what is free, never onto a used number: ${cid[*]}"
pass "group_monitors: monitors run left to right and moves wait for a free number"

# Already grouped: nothing to do. A persistent workspace keeps its number.
write_stub '{"id":1}' \
  '[{"name":"A","x":0,"y":0,"focused":true,"activeWorkspace":{"id":1}},{"name":"B","x":100,"y":0,"activeWorkspace":{"id":3}}]' \
  '[{"id":1,"name":"1","monitor":"A","windows":1},{"id":2,"name":"2","monitor":"A","windows":1},{"id":3,"name":"3","monitor":"B","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xb","workspace":{"id":2}},{"address":"0xc","workspace":{"id":3}}]'
out=$(PLONK_GROUP_MONITORS=on run_plonk)
[[ $out == "plonk: Already Plonked!" && ! -s $log ]] || fail "a grouped layout is left alone, got: $out"
write_stub '{"id":1}' \
  '[{"name":"A","x":0,"y":0,"focused":true,"activeWorkspace":{"id":1}},{"name":"B","x":100,"y":0,"activeWorkspace":{"id":4}}]' \
  '[{"id":1,"name":"1","monitor":"A","windows":1},{"id":2,"name":"2","monitor":"A","windows":0,"ispersistent":true},{"id":4,"name":"4","monitor":"B","windows":1}]' \
  '[{"address":"0xa","workspace":{"id":1}},{"address":"0xc","workspace":{"id":4}}]'
PLONK_GROUP_MONITORS=on run_plonk >/dev/null
grep -E 'id = 2\b' "$log" >/dev/null && fail "never lands on a persistent workspace's number, log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "4", id = 3 })' "$log" >/dev/null || fail "packs around the persistent one, log=$(cat "$log")"
pass "group_monitors: a grouped layout is a no-op and persistent numbers are respected"

# Unknown value is refused loudly and treated as off.
out=$(PLONK_GROUP_MONITORS=maybe run_plonk 2>&1 >/dev/null || true)
grep -F "unknown group_monitors mode 'maybe'" <<<"$out" >/dev/null || fail "bad group_monitors value warns, got: $out"
pass "group_monitors: unknown value warns and stays off"

echo "all tests passed"
