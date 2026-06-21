# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A WezTerm plugin that displays Claude API usage quota in the terminal status bar. It reads OAuth credentials from `~/.claude/.credentials.json`, polls the Anthropic usage API (`/api/oauth/usage`), and renders 5-hour and 7-day utilization percentages with color-coded thresholds and countdown timers until reset.

## Architecture

Single-file Lua plugin at `plugin/init.lua`. WezTerm loads it via its plugin system. The module exports `M.apply_to_config(config, opts)` which hooks into WezTerm's `update-status` event.

**Key flow:** `apply_to_config` → registers `update-status` handler → `fetch_usage()` (cached curl to Anthropic API) → `build_cells()` → renders to left or right status bar.

**Configurable options** (passed via `opts` table to `apply_to_config`):
- `poll_interval_secs` (default 60)
- `position` ("left" or "right")
- `icons` table (week)

## Development

This is a pure Lua plugin with no build step, dependencies, or tests. Edit `plugin/init.lua` directly. Test by reloading WezTerm config.

The plugin uses `wezterm.run_child_process` to shell out to `curl` for API calls and `wezterm.json_parse` for JSON parsing — both are WezTerm built-ins, not standard Lua.

## Color Scheme

Supports configurable palettes via the `colors` option: `"dark"` (Tokyo Night — default), `"light"` (high-contrast for light backgrounds), `"auto"` (follows system appearance), or a custom table of hex values. Colors are resolved dynamically on each render via `resolve_palette()`, so `"auto"` reacts to macOS appearance changes without restarting.
