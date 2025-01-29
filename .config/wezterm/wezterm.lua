local env = require("env")
local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.default_prog = { env.wsl_path, "--cd", "~" }

config.font = wezterm.font("JetBrains Mono")
config.color_scheme = "AdventureTime"
config.default_cursor_style = "SteadyBar"

config.background = require("background")

return config
