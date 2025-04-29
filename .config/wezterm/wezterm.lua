local env = require("env")
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- 同じディレクトリにあるすべてのLuaファイルを読み込む
local function load_all_lua_files()
    local files = wezterm.glob("*.lua")
    for _, file in ipairs(files) do
        if file ~= "wezterm.lua" then
            require(file:gsub("%.lua$", ""))
        end
    end
end

load_all_lua_files()


config.default_prog = { env.wsl_path, "--cd", "~" }

config.font = wezterm.font("JetBrains Mono")
config.color_scheme = "AdventureTime"
config.default_cursor_style = "SteadyBar"

config.background = require("background")

return config
