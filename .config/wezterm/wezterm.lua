local env = require("env")
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- WSL起動設定
-- config.default_prog = { env.wsl_path, "--cd", "~" }
config.default_prog = { "pwsh.exe" }

-- 描画専用化（キー・タブ管理を無効化）
config.disable_default_key_bindings = true
config.enable_tab_bar = false
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true

-- フォント設定（CJKフォールバック付き）
config.font = wezterm.font_with_fallback {
  "JetBrains Mono",
  "Noto Sans Mono CJK JP",
}
config.font_size = 12.0
config.line_height = 1.2

-- 可読性向上
config.scrollback_lines = 10000
config.default_cursor_style = "SteadyBar"
config.color_scheme = "AdventureTime"

-- 背景設定
config.background = require("background")

-- キーバインド（クリップボード処理のみ）
config.keys = require("keys")

return config
