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
run_plonk --bogus >/dev/null 2>&1 && fail "unknown flag should exit non-zero" || true
[[ ! -s $log ]] || fail "unknown flag does not dispatch"
run_plonk -n extra >/dev/null 2>&1 && fail "extra args should exit non-zero" || true
pass "rejects unknown args and --help does not plonk"

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

echo "all tests passed"
