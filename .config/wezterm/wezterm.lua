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

-- フォント: HackGen Console (英数字は Hack、日本語は源柔ゴシックを合成したもの。日本語も同じフォントで描く)
-- lenovo にはユーザー単位で入れてある (%LOCALAPPDATA%\Microsoft\Windows\Fonts)
config.font = wezterm.font("HackGen Console")
config.font_size = 12.0
config.line_height = 1.2
-- 文字の大きさを変えたとき (Ctrl+↑ / Ctrl+↓)、ウィンドウの大きさを保ち、行数と桁数のほうを変える
config.adjust_window_size_when_changing_font_size = false

-- 可読性向上
config.scrollback_lines = 10000
config.default_cursor_style = "SteadyBar"
-- 配色は Tokyo Night。本文の文字色 (#c0caf5) は青みがかって読みにくいので、白にする。
-- 組み込みの配色を写し、文字色だけを変えたものを登録して使う。
local scheme = wezterm.color.get_builtin_schemes()["Tokyo Night"]
scheme.foreground = "#ffffff"
config.color_schemes = { ["Tokyo Night White Text"] = scheme }
config.color_scheme = "Tokyo Night White Text"

-- 背景設定
-- ウィンドウ背景を素通しにして、その上に background.lua の黒ティントを 1 枚だけ敷く。
-- 🔴 背景レイヤーはこの「ウィンドウ背景」より手前に描かれるので、
--    window_background_opacity は不透明なレイヤーを敷いた時点で意味を失う (実測)。
-- 🔴 "Disable" 以外 (Mica / Tabbed / Acrylic) を使う場合、Windows の「透明効果」が
--    オフだとエラーも警告も無く単なる黒になる。
config.window_background_opacity = 0
config.win32_system_backdrop = "Disable"
config.background = require("background")

-- キーバインド（クリップボード処理のみ）
config.keys = require("keys")

-- herdr の Windows クライアントが win32-input-mode (ESC[?9001h) を要求すると、
-- wezterm は貼り付けを bracketed paste ではなくキーレコード列として送るようになり、
-- Ctrl+Shift+V の Ctrl が改行の Enter に乗って ESC[27;5;13~ に化け、改行が消える。
-- "win32" 以外を入れると herdr はこのモードを要求しない。
config.set_environment_variables = {
  HERDR_WINDOWS_INPUT_PROBE = "vt",
}

return config
