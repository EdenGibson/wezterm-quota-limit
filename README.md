# wezterm-quota-limit

A WezTerm plugin that shows your Claude API usage quota directly in the terminal status bar.

![Status bar showing 5-hour and 7-day usage](https://img.shields.io/badge/WezTerm-plugin-blue)

## What it shows

```
5h 42% (2h31m) cap ~3h12m  | 7d 18% (4d12h)
```

- **5-hour window** — current utilization percentage and time until reset
- **7-day window** — current utilization percentage and time until reset
- **Burn rate** — estimated time until you hit 100% ("cap"), based on recent usage trend
- Color-coded: green (< 50%), yellow (50-79%), red (>= 80%)

## Prerequisites

- [WezTerm](https://wezfurlong.org/wezterm/) with plugin support
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (macOS Keychain or `~/.claude/.credentials.json`)
- `curl` available on PATH

## Installation

Add to your `~/.wezterm.lua`:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local quota = wezterm.plugin.require("https://github.com/EdenGibson/wezterm-quota-limit")
quota.apply_to_config(config)

return config
```

To update the plugin, run in WezTerm:

```
wezterm.plugin.update_all()
```

## Configuration

Pass an options table as the second argument to `apply_to_config`:

```lua
quota.apply_to_config(config, {
  poll_interval_secs = 120,  -- how often to fetch usage (default: 60)
  position = "left",         -- "left" or "right" status bar (default: "right")
  colors = "auto",           -- "dark", "light", "auto", or custom table (default: "dark")
  icons = {
    week = "▪",               -- separator before 7-day window
  },
})
```

### Color schemes

The `colors` option controls the palette used for usage indicators:

| Value | Behavior |
|-------|----------|
| `"dark"` | Tokyo Night palette — good for dark backgrounds (default) |
| `"light"` | High-contrast palette — good for light backgrounds |
| `"auto"` | Follows macOS/system appearance, switching between dark and light |
| `{ ... }` | Custom colors (see below) |

For full control, pass a table with any combination of these keys:

```lua
colors = {
  green  = "#40a02b",  -- < 50% usage
  yellow = "#df8e1d",  -- 50-79% usage
  red    = "#d20f39",  -- >= 80% usage
  dim    = "#6c6f85",  -- labels and separators
  bright = "#4c4f69",  -- "5h" / "7d" headings
}
```

Any omitted keys fall back to the dark palette defaults.

## Type Annotations

Lua LSP types are available via [wezterm-types](https://github.com/DrKJeff16/wezterm-types).

## How it works

The plugin reads your Claude Code OAuth token and polls the Anthropic usage API every 60 seconds (configurable). On macOS, it first tries the macOS Keychain (where Claude Code stores credentials natively), then falls back to `~/.claude/.credentials.json`. On other platforms, it reads the credentials file directly. Results are cached between polls. The status bar updates on every WezTerm `update-status` event, but only makes a network request when the cache expires.

### Token management

The plugin re-reads the token on every poll, so it automatically picks up tokens refreshed by Claude Code. If the token has expired or auth fails (401/403), it waits for Claude Code to refresh the credentials rather than attempting its own token refresh. When it detects a new token, error state resets and normal polling resumes.

### Burn rate estimates

The plugin tracks the last 10 successful usage readings and calculates a linear burn rate. If usage is increasing, it estimates how long until you hit 100% capacity ("cap") for each window. The cap indicator is color-coded by urgency: red (< 30 min), yellow (< 1 hour), dim (> 1 hour).

### Error handling

- **Exponential backoff** on consecutive errors: 2min, 4min, 8min, 16min, capped at 30min. Resets to normal polling on success.
- **Stale data preservation** — if a fetch fails but previous data exists, the last successful result is shown (not an error).
- **Crash protection** — the status bar handler is wrapped in `pcall` so an unexpected error won't break your WezTerm status bar.

## License

MIT
