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

Hyprland has no "renumber workspace" dispatcher, so plonk moves every window from each occupied workspace into the lowest free slot, ascending — the target is always empty by construction. Focus follows your active workspace to its new number.

- Special/scratchpad workspaces (id < 1) are left alone
- Multi-monitor aware (compacts per monitor)
- Idempotent — safe to mash the key

Dependencies: `hyprctl`, `jq` (both ship with Omarchy).

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

## License

MIT
