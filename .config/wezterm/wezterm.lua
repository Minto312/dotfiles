local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.font = wezterm.font("JetBrains Mono")
config.color_scheme = "AdventureTime"

config.window_background_image = '/path/to/wallpaper.jpg'
config.window_background_opacity = 1.0

return config
