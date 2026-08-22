# plonk

Collapse your Hyprland workspaces down to the lowest numbers.

You open windows on workspaces 1–11. You close a few. Now workspaces 3, 4, 5, 7, 8, 9, 10, 11 are occupied and 1, 2, 6 are holes. `plonk` squashes them back to 1–8 in one keystroke.

Built for [Omarchy](https://omarchy.org) (Hyprland ≥ 0.56 Lua dispatchers, with legacy-syntax fallback for older Hyprland).

```
$ plonk -n          # dry run
would move workspace 3 -> 1 (eDP-1)
would move workspace 4 -> 2 (eDP-1)
would move workspace 5 -> 3 (eDP-1)
would move workspace 7 -> 4 (eDP-1)
...
$ plonk             # do it
$ plonk
plonk: already compact
```

## How it works

Hyprland workspace IDs are global. Plonk walks occupied numeric workspaces in ascending order and packs them into 1..N, so the destination ID is free (or is an empty persistent workspace). It prefers `hl.dsp.workspace.change_id` — the workspace stays on its monitor and keeps its layout — and only moves windows when that ID is already taken. Focus follows your active workspace to its new number.

- Special/scratchpad workspaces (id < 1) are left alone
- Named workspaces are left alone
- Multi-monitor: fills holes in the global number line; workspaces do not jump heads
- Idempotent — safe to mash the key

Dependencies: `hyprctl`, `jq` (both ship with Omarchy). `bash test.sh` runs the stubbed regression tests (no live compositor required).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/nixfred/plonk/main/plonk -o ~/.local/bin/plonk && chmod +x ~/.local/bin/plonk
```

## Keybind (Omarchy)

Add to `~/.config/hypr/bindings.lua`, then `hyprctl reload`:

```lua
o.bind("SUPER + MINUS", "Plonk: compact workspaces", "plonk")
```

(`SUPER + MINUS` is unbound in stock Omarchy as of 4.x. Check `hyprctl binds -j` before choosing another.)

For plain Hyprland `.conf`:

```
bind = SUPER, MINUS, exec, plonk
```

## Upstream

Proposed for Omarchy proper as `omarchy-hyprland-workspace-compact`: [basecamp/omarchy#7727](https://github.com/basecamp/omarchy/pull/7727). Discussion: [Show and Tell #7728](https://github.com/basecamp/omarchy/discussions/7728).

## License

MIT
