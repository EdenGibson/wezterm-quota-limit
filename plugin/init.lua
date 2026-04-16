local wezterm = require("wezterm")

local M = {}

-- Config defaults
local config = {
  poll_interval_secs = 60,
  position = "right", -- "left" or "right"
  dashboard_key = { key = "u", mods = "CTRL|SHIFT" }, -- keybind to open dashboard
  colors = "dark", -- "dark", "light", "auto", or a table { green, yellow, red, dim, bright }
  icons = {
    bolt = "⚡",
    week = "▪",
  },
}

-- Built-in color palettes
local PALETTES = {
  dark = {
    green  = "#9ece6a",
    yellow = "#e0af68",
    red    = "#f7768e",
    dim    = "#565f89",
    bright = "#c0caf5",
  },
  light = {
    green  = "#40a02b",
    yellow = "#df8e1d",
    red    = "#d20f39",
    dim    = "#6c6f85",
    bright = "#4c4f69",
  },
}

-- Resolve which palette to use based on config.colors and system appearance
local function resolve_palette()
  local c = config.colors
  if type(c) == "table" then
    -- User provided explicit colors; fill any gaps from the dark palette
    local base = PALETTES.dark
    return {
      green  = c.green  or base.green,
      yellow = c.yellow or base.yellow,
      red    = c.red    or base.red,
      dim    = c.dim    or base.dim,
      bright = c.bright or base.bright,
    }
  end
  if c == "auto" then
    local ok, appearance = pcall(wezterm.gui.get_appearance)
    if ok and appearance and appearance:find("Dark") then
      return PALETTES.dark
    else
      return PALETTES.light
    end
  end
  return PALETTES[c] or PALETTES.dark
end

-- Cached usage data
local cached_data = nil
local last_fetch_time = 0
local consecutive_errors = 0
local last_error = nil
local handler_registered = false
local cached_token = nil

-- Burn rate tracking
local usage_history = {} -- array of {time, five, seven}
local MAX_HISTORY = 10

-- ANSI escape helpers (bypass wezterm.format to avoid nightly deserialization bugs)
local ESC = "\x1b["
local RESET = ESC .. "0m"

local function hex_to_fg(hex)
  if type(hex) ~= "string" or not hex:match("^#%x%x%x%x%x%x$") then
    wezterm.log_warn("claude-usage: invalid hex color '" .. tostring(hex) .. "', falling back to white")
    return ESC .. "38;2;255;255;255m"
  end
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return ESC .. "38;2;" .. r .. ";" .. g .. ";" .. b .. "m"
end

-- Color helpers — resolved dynamically from the active palette
local function usage_color_esc(pct)
  local p = resolve_palette()
  if pct >= 80 then return hex_to_fg(p.red)
  elseif pct >= 50 then return hex_to_fg(p.yellow)
  else return hex_to_fg(p.green) end
end

local function dim_esc()
  return hex_to_fg(resolve_palette().dim)
end

local function bright_esc()
  return hex_to_fg(resolve_palette().bright)
end

-- Legacy FormatItem helpers (kept for compatibility if wezterm.format works)
local function usage_color(pct)
  local p = resolve_palette()
  if pct >= 80 then return { Foreground = { Color = p.red } }
  elseif pct >= 50 then return { Foreground = { Color = p.yellow } }
  else return { Foreground = { Color = p.green } } end
end

local function dim()
  return { Foreground = { Color = resolve_palette().dim } }
end

local function bright()
  return { Foreground = { Color = resolve_palette().bright } }
end

-- Deep merge: t2 values override t1, recurses into nested tables
local function deep_merge(t1, t2)
  local result = {}
  for k, v in pairs(t1) do
    result[k] = v
  end
  for k, v in pairs(t2) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- Credentials file path
local function cred_path()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
  return home .. "/.claude/.credentials.json"
end

-- Read credentials from macOS Keychain
local function read_keychain()
  local success, stdout, stderr = wezterm.run_child_process({
    "security", "find-generic-password",
    "-s", "Claude Code-credentials",
    "-w",
  })
  if success and stdout and stdout ~= "" then
    return stdout:gsub("%s+$", ""), nil
  end
  return nil, "keychain: no credential found"
end

-- Read credentials file (tries macOS Keychain first on Apple systems)
local function read_credentials()
  local is_mac = (wezterm.target_triple or ""):find("apple") ~= nil
  if is_mac then
    local content, err = read_keychain()
    if content then
      return content, nil
    end
  end

  local path = cred_path()
  local f = io.open(path, "r")
  if not f then
    f = io.open(path:gsub("/", "\\"), "r")
  end
  if not f then
    return nil, "no credentials file"
  end
  local content = f:read("*a")
  f:close()
  return content, nil
end

-- Read OAuth token and expiry from credentials file
local function get_token()
  local content, err = read_credentials()
  if not content then
    return nil, nil, err
  end

  local token = content:match('"claudeAiOauth"%s*:%s*{[^}]*"accessToken"%s*:%s*"([^"]+)"')
  if not token then
    return nil, nil, "no accessToken in credentials"
  end

  local expires_at = content:match('"expiresAt"%s*:%s*(%d+)')
  return token, tonumber(expires_at), nil
end

-- Format time remaining until reset
local function time_until(reset_str)
  if not reset_str then
    return "?"
  end

  -- Parse ISO 8601: 2026-03-08T04:59:59.000000+00:00
  local year, month, day, hour, min, sec =
    reset_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return "?"
  end

  local reset_time = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })

  -- reset_str is UTC, os.time gives local — adjust
  local now_local = os.time()
  local now_utc = os.time(os.date("!*t", now_local))
  local diff = reset_time - now_utc

  if diff <= 0 then
    return "now"
  elseif diff < 3600 then
    return string.format("%dm", math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format("%dh%dm", math.floor(diff / 3600), math.floor((diff % 3600) / 60))
  else
    return string.format("%dd%dh", math.floor(diff / 86400), math.floor((diff % 86400) / 3600))
  end
end

-- Record a successful usage reading for burn rate calculation
local function record_usage(data)
  if not data or data.error then
    return
  end
  local five = data.five_hour and data.five_hour.utilization or 0
  local seven = data.seven_day and data.seven_day.utilization or 0
  table.insert(usage_history, { time = os.time(), five = five, seven = seven })
  while #usage_history > MAX_HISTORY do
    table.remove(usage_history, 1)
  end
end

-- Estimate seconds until a usage field hits 100%, or nil if not increasing
local function estimate_cap_secs(field)
  if #usage_history < 2 then
    return nil
  end
  local newest = usage_history[#usage_history]
  -- Walk backward to find the oldest reading that's still part of a
  -- continuous increase (skip readings from before a window reset)
  local start_idx = #usage_history
  for i = #usage_history - 1, 1, -1 do
    if usage_history[i][field] > newest[field] then
      break
    end
    start_idx = i
  end
  if start_idx >= #usage_history then
    return nil
  end
  local oldest = usage_history[start_idx]
  local dt = newest.time - oldest.time
  if dt <= 0 then
    return nil
  end
  local dp = newest[field] - oldest[field]
  if dp <= 0 then
    return nil
  end
  local remaining = 100 - newest[field]
  if remaining <= 0 then
    return 0
  end
  return remaining / (dp / dt)
end

-- Format seconds-to-cap as a short string
local function format_cap_time(secs)
  if secs <= 0 then
    return "now"
  elseif secs < 60 then
    return "<1m"
  elseif secs < 3600 then
    return string.format("~%dm", math.floor(secs / 60))
  elseif secs < 86400 then
    return string.format("~%dh%dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  else
    return ">1d"
  end
end

-- Color for burn rate based on urgency
local function cap_color(secs)
  local p = resolve_palette()
  if secs < 1800 then
    return { Foreground = { Color = p.red } }
  elseif secs < 3600 then
    return { Foreground = { Color = p.yellow } }
  else
    return dim()
  end
end

local function cap_color_esc(secs)
  local p = resolve_palette()
  if secs < 1800 then
    return hex_to_fg(p.red)
  elseif secs < 3600 then
    return hex_to_fg(p.yellow)
  else
    return dim_esc()
  end
end

-- Calculate how long to wait before next fetch (exponential backoff on errors)
local function current_interval()
  if consecutive_errors == 0 then
    return config.poll_interval_secs
  end
  -- Back off: 2min, 4min, 8min, 16min, capped at 30min
  local backoff = math.min(120 * (2 ^ (consecutive_errors - 1)), 1800)
  return backoff
end

-- Detect Claude Code version (cached after first call)
local claude_version = nil
local function get_claude_version()
  if claude_version then
    return claude_version
  end
  local ok, stdout = pcall(function()
    local success, out = wezterm.run_child_process({ "claude", "--version" })
    if success and out then
      return out
    end
    return nil
  end)
  if ok and stdout then
    local ver = stdout:match("(%d+%.%d+%.%d+)")
    if ver then
      claude_version = ver
      return claude_version
    end
  end
  claude_version = "0.0.0"
  return claude_version
end

-- Make an API request to the usage endpoint
local function call_usage_api(token)
  local success, stdout, stderr = wezterm.run_child_process({
    "curl",
    "-s",
    "-m", "5",
    "-w", "\n%{http_code}",
    "https://api.anthropic.com/api/oauth/usage",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "Content-Type: application/json",
    "-H", "User-Agent: claude-code/" .. get_claude_version(),
  })

  if not success or not stdout or stdout == "" then
    return nil, nil, "curl failed"
  end

  local body, http_code = stdout:match("^(.*)\n(%d+)$")
  if not body then
    return stdout, nil, nil
  end

  return body, tonumber(http_code), nil
end

-- Fetch usage data (synchronous curl call cached at the polling interval)
local function fetch_usage()
  local now = os.time()
  local interval = current_interval()
  if (now - last_fetch_time) < interval then
    return cached_data or { error = last_error or "waiting..." }
  end

  -- Re-read token from disk each fetch — Claude Code may have refreshed it
  local token, expires_at, err = get_token()
  if not token then
    last_fetch_time = now
    last_error = err
    return cached_data or { error = err }
  end

  -- If the token changed on disk (Claude Code refreshed it), reset error state
  if cached_token and token ~= cached_token then
    consecutive_errors = 0
    last_error = nil
  end
  cached_token = token

  -- If the token is expired, don't call the API — wait for Claude Code to refresh
  local now_ms = math.floor(now * 1000)
  if expires_at and now_ms >= expires_at then
    last_fetch_time = now
    last_error = "token expired — waiting for Claude Code"
    return cached_data or { error = last_error }
  end

  local body, status, curl_err = call_usage_api(token)

  if curl_err then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = curl_err
    return cached_data or { error = last_error }
  end

  if status == 429 then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    local wait = current_interval()
    last_error = string.format("rate limited (retry in %dm)", math.ceil(wait / 60))
    return cached_data or { error = last_error }
  end

  if status == 401 or status == 403 then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "auth failed — waiting for Claude Code"
    return cached_data or { error = last_error }
  end

  local ok, data = pcall(wezterm.json_parse, body)
  if not ok or not data then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = "parse failed"
    return cached_data or { error = last_error }
  end

  if data.error then
    last_fetch_time = now
    consecutive_errors = consecutive_errors + 1
    last_error = data.error.message or "api error"
    return cached_data or { error = last_error }
  end

  -- Success — reset error state and record for burn rate
  cached_data = data
  last_fetch_time = now
  consecutive_errors = 0
  last_error = nil
  record_usage(data)
  return data
end

-- Dashboard URL
local DASHBOARD_URL = "https://console.anthropic.com/settings/usage"

-- Build status string using raw ANSI escapes (avoids wezterm.format deserialization issues)
local function build_status_string(data)
  local p = resolve_palette()
  local D = dim_esc()
  local B = bright_esc()

  if data.error then
    return D .. " " .. config.icons.bolt .. " Claude: "
      .. hex_to_fg(p.red) .. tostring(data.error) .. " " .. RESET
  end

  local five_pct = data.five_hour and data.five_hour.utilization or 0
  local five_reset = data.five_hour and data.five_hour.resets_at
  local seven_pct = data.seven_day and data.seven_day.utilization or 0
  local seven_reset = data.seven_day and data.seven_day.resets_at
  local five_cap = estimate_cap_secs("five")
  local seven_cap = estimate_cap_secs("seven")

  local s = D .. " " .. config.icons.bolt .. " "
    .. B .. "5h "
    .. usage_color_esc(five_pct) .. string.format("%.0f%%", five_pct)
    .. D .. " (" .. time_until(five_reset) .. ")"

  if five_cap then
    s = s .. cap_color_esc(five_cap) .. " cap " .. format_cap_time(five_cap)
  end

  s = s .. D .. "  " .. config.icons.week .. " "
    .. B .. "7d "
    .. usage_color_esc(seven_pct) .. string.format("%.0f%%", seven_pct)
    .. D .. " (" .. time_until(seven_reset) .. ")"

  if seven_cap then
    s = s .. cap_color_esc(seven_cap) .. " cap " .. format_cap_time(seven_cap)
  end

  return s .. " " .. RESET
end

-- Build status bar cells (legacy, for wezterm.format)
local function build_cells(data)
  local cells = {}

  if data.error then
    table.insert(cells, dim())
    table.insert(cells, { Text = " " .. config.icons.bolt .. " Claude: " })
    table.insert(cells, { Foreground = { Color = resolve_palette().red } })
    table.insert(cells, { Text = tostring(data.error) .. " " })
    return cells
  end

  -- 5-hour window
  local five_pct = data.five_hour and data.five_hour.utilization or 0
  local five_reset = data.five_hour and data.five_hour.resets_at

  -- 7-day window
  local seven_pct = data.seven_day and data.seven_day.utilization or 0
  local seven_reset = data.seven_day and data.seven_day.resets_at

  -- Icon
  table.insert(cells, dim())
  table.insert(cells, { Text = " " .. config.icons.bolt .. " " })

  -- Burn rate estimates
  local five_cap = estimate_cap_secs("five")
  local seven_cap = estimate_cap_secs("seven")

  -- 5h usage
  table.insert(cells, bright())
  table.insert(cells, { Text = "5h " })
  table.insert(cells, usage_color(five_pct))
  table.insert(cells, { Text = string.format("%.0f%%", five_pct) })
  table.insert(cells, dim())
  table.insert(cells, { Text = " (" .. time_until(five_reset) .. ")" })
  if five_cap then
    table.insert(cells, cap_color(five_cap))
    table.insert(cells, { Text = " cap " .. format_cap_time(five_cap) })
  end

  -- Separator
  table.insert(cells, dim())
  table.insert(cells, { Text = "  " .. config.icons.week .. " " })

  -- 7d usage
  table.insert(cells, bright())
  table.insert(cells, { Text = "7d " })
  table.insert(cells, usage_color(seven_pct))
  table.insert(cells, { Text = string.format("%.0f%%", seven_pct) })
  table.insert(cells, dim())
  table.insert(cells, { Text = " (" .. time_until(seven_reset) .. ")" })
  if seven_cap then
    table.insert(cells, cap_color(seven_cap))
    table.insert(cells, { Text = " cap " .. format_cap_time(seven_cap) })
  end
  table.insert(cells, { Text = " " })

  return cells
end

function M.apply_to_config(c, opts)
  if opts then
    config = deep_merge(config, opts)
  end

  -- Add keybinding to open usage dashboard
  if config.dashboard_key then
    local act = wezterm.action
    local keys = c.keys or {}
    table.insert(keys, {
      key = config.dashboard_key.key,
      mods = config.dashboard_key.mods,
      action = act.EmitEvent("open-claude-dashboard"),
    })
    c.keys = keys

    wezterm.on("open-claude-dashboard", function()
      wezterm.open_with(DASHBOARD_URL)
    end)
  end

  -- Guard against duplicate handler registration
  if handler_registered then
    return
  end
  handler_registered = true

  wezterm.on("update-status", function(window, pane)
    local ok, err = pcall(function()
      local data = fetch_usage()
      local status = build_status_string(data)

      if config.position == "left" then
        window:set_left_status(status)
      else
        window:set_right_status(status)
      end
    end)
    if not ok then
      wezterm.log_error("claude-usage: " .. tostring(err))
    end
  end)
end

return M
