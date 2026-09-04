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

echo "all tests passed"
