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

# --- workspace-names.json titles travel with the workspace ------------------
names="$tmpdir/workspace-names.json"
printf '%s\n' '{"_config":{"hold":900},"1":"Plonk","3":"Brave","4":"Voice","7":"Blank","9":"Stale"}' >"$names"
: >"$log"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -r '."1"' "$names") == Brave ]] || fail "3 -> 1 carries 'Brave' onto the empty slot (was 'Plonk'), got: $(cat "$names")"
[[ $(jq -r '."2"' "$names") == Voice ]] || fail "4 -> 2 carries 'Voice', got: $(cat "$names")"
[[ $(jq -r '."3"' "$names") == Blank ]] || fail "7 -> 3 carries 'Blank' (overwriting stale 'Brave'), got: $(cat "$names")"
[[ $(jq -r 'has("4")' "$names") == false && $(jq -r 'has("7")' "$names") == false ]] || fail "old keys removed, got: $(cat "$names")"
[[ $(jq -r '."9"' "$names") == Stale ]] || fail "names of workspaces plonk did not touch stay put"
[[ $(jq -r '._config.hold' "$names") == 900 ]] || fail "_config preserved"
ls "$tmpdir"/workspace-names.json.* >/dev/null 2>&1 && fail "no temp files left behind"
grep -F 'rename' "$log" >/dev/null && fail "never touches Hyprland workspace names"
pass "workspace-names.json titles travel with renumbered workspaces"

# an UNNAMED workspace arriving on a slot never deletes the slot's title
# (titles are sticky; plonk must never remove a name on its own)
printf '%s\n' '{"1":"Keep","2":"Me"}' >"$names"
WORKSPACE_NAMES_FILE="$names" run_plonk >/dev/null
[[ $(jq -c . "$names") == '{"1":"Keep","2":"Me"}' ]] || fail "unnamed arrivals must not touch existing titles, got: $(cat "$names")"
pass "plonk never deletes a title on its own"
ls "$tmpdir/state-sandbox/names-backups"/workspace-names.*.json >/dev/null 2>&1 || fail "a names backup is written before any remap"
pass "names file is backed up before plonk rewrites it"

# notifications coalesce: two runs inside 2s -> one notification
cat >"$stub/omarchy-notification-send" <<'EOF3'
#!/bin/bash
echo "notify $*" >>"$NOTIFY_LOG"
EOF3
chmod +x "$stub/omarchy-notification-send"
nlog="$tmpdir/notify.log"; : >"$nlog"
rm -f "$tmpdir/state-sandbox/last-notify"
NOTIFY_LOG="$nlog" run_plonk >/dev/null
NOTIFY_LOG="$nlog" run_plonk >/dev/null
NOTIFY_LOG="$nlog" run_plonk >/dev/null
[[ $(grep -c '^notify' "$nlog") == 1 ]] || fail "three runs within 2s must notify once, got: $(cat "$nlog")"
pass "notifications coalesce to one per 2s"
rm -f "$stub/omarchy-notification-send"

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

echo "all tests passed"
