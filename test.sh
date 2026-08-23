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
stub="$tmpdir/bin"
log="$tmpdir/hyprctl.log"
mkdir -p "$stub"

write_stub() {
  local active=$1 monitors=$2 workspaces=$3 clients=$4
  cat >"$stub/hyprctl" <<EOF
#!/bin/bash
case "\$1" in
  activeworkspace) printf '%s\\n' '$active' ;;
  monitors) printf '%s\\n' '$monitors' ;;
  workspaces) printf '%s\\n' '$workspaces' ;;
  clients) printf '%s\\n' '$clients' ;;
  dispatch) printf '%s\\n' "\$*" >>"$log"; echo ok ;;
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
[[ $out == "Usage: plonk [-n|--dry-run] | plonk --watch [--notify]" ]] || fail "--help prints usage"
[[ ! -s $log ]] || fail "--help does not dispatch"
out=$(env -u HOME -u XDG_CONFIG_HOME PATH="$stub:$PATH" "$PLONK" --help) || fail "--help should work without HOME"
[[ $out == "Usage: plonk [-n|--dry-run] | plonk --watch [--notify]" ]] || fail "--help without HOME prints usage"
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
[[ $out == "plonk: already compact" ]] || fail "already compact message, got: $out"
[[ ! -s $log ]] || fail "already compact does not dispatch"
out=$(run_plonk -n)
[[ $out == "plonk: already compact" ]] || fail "dry-run already compact message, got: $out"
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
grep -Fx 'moved workspace 7 -> 3 (eDP-1)' <<<"$out" >/dev/null || fail "prints the move, got: $out"
pass "collapses gaps with change_id, skips special, refocuses"

# --- workspace-names.json titles are anchors ---------------------------------
# Fixture: 3, 4, 7 occupied; titles on 1 and 4. Slot 1 is titled (empty) so
# nothing may land there; workspace 4 is titled so it must not move.
# Expected: 3 -> 2, 7 -> 3 (slot 1 reserved, 4 anchored), file untouched.
names="$tmpdir/workspace-names.json"
printf '%s\n' '{"_config":{"hold":900},"1":"Plonk","4":"Browser"}' >"$names"
before=$(cat "$names")
: >"$log"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(cat "$names") == "$before" ]] || fail "plonk must never write the names file, got: $(cat "$names")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 2 })' "$log" >/dev/null || fail "3 -> 2 (slot 1 is titled, reserved), log=$(cat "$log")"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "7", id = 3 })' "$log" >/dev/null || fail "7 -> 3 (4 is titled, anchored), log=$(cat "$log")"
grep -E 'workspace = "4"|id = 4 |id = 1 ' "$log" >/dev/null && fail "titled workspace/slot touched, log=$(cat "$log")"
ls "$tmpdir"/workspace-names.json.* >/dev/null 2>&1 && fail "no temp files next to the names file"
pass "titled workspaces are anchors: never moved, never landed on, file untouched"

# names file missing -> behaves as before, never creates one
: >"$log"
WORKSPACE_NAMES_FILE="$tmpdir/does-not-exist.json" run_plonk >/dev/null || fail "missing names file must not fail"
[[ ! -e "$tmpdir/does-not-exist.json" ]] || fail "does not create a names file"
grep -Fx 'dispatch hl.dsp.workspace.change_id({ workspace = "3", id = 1 })' "$log" >/dev/null || fail "without titles, 3 -> 1 as usual"
pass "no names file is fine"

# XDG_CONFIG_HOME is the standard config root and HOME may be absent in a
# minimal service environment.
# Titles are anchors: if the XDG-path file is honored, titled workspace 3
# stays put (the previous test shows 3 -> 1 when no titles are found) and
# the file is never written.
mkdir -p "$tmpdir/xdg/omarchy"
printf '%s\n' '{"3":"XDG title"}' >"$tmpdir/xdg/omarchy/workspace-names.json"
cp "$tmpdir/xdg/omarchy/workspace-names.json" "$tmpdir/xdg-before.json"
: >"$log"
env -u HOME -u WORKSPACE_NAMES_FILE XDG_CONFIG_HOME="$tmpdir/xdg" PATH="$stub:$PATH" "$PLONK" >/dev/null || fail "runs without HOME when XDG_CONFIG_HOME is set"
grep -F 'workspace = "3"' "$log" >/dev/null && fail "titled workspace 3 from XDG_CONFIG_HOME must not move, log=$(cat "$log")"
cmp -s "$tmpdir/xdg-before.json" "$tmpdir/xdg/omarchy/workspace-names.json" || fail "names file under XDG_CONFIG_HOME must not be rewritten"
pass "workspace title path follows XDG_CONFIG_HOME without requiring HOME"

# --- dry run prints the plan and dispatches nothing ------------------------
: >"$log"
out=$(run_plonk --dry-run)
[[ -s $log ]] && fail "dry run does not dispatch"
grep -Fx 'would move workspace 7 -> 3 (eDP-1)' <<<"$out" >/dev/null || fail "dry run prints the plan, got: $out"
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
[[ $out == "plonk: already compact" ]] || fail "named workspace is not compacted, got: $out"
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
[[ $out != *moved* ]] || fail "watch is quiet, got: $out"
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

echo "all tests passed"
