-- Alt+V: 手元 (Windows) のクリップボードの画像を develop の ~/.cache/clip-images/ に送り、
-- develop 上の絶対パスを今のペインに貼り付ける。Claude Code は貼られた画像のパスを画像として読む。
-- tmux 越しの Claude Code は手元のクリップボードを見られないので、その代わりに使う。
--
-- 実際の処理は clip-image-send.ps1 (wezterm と同じフォルダ) が行う。
-- wezterm.run_child_process は子プロセスを非同期に待つので、送る間も画面は固まらない。
-- 画像が無いとき・送れなかったときは何も貼らず、通知 (toast) で理由を出す。
local wezterm = require("wezterm")

local M = {}

local script = wezterm.config_dir .. "/clip-image-send.ps1"
local title = "画像の貼り付け (Alt+V)"

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.paste(window, pane)
  local ok, success, stdout, stderr = pcall(wezterm.run_child_process, {
    "pwsh.exe", "-NoProfile", "-NonInteractive", "-STA",
    "-ExecutionPolicy", "Bypass", "-File", script,
  })
  if not ok then
    -- pwsh.exe を起動できなかったとき
    window:toast_notification(title, "pwsh.exe を起動できませんでした: " .. tostring(success), nil, 6000)
    return
  end

  local out = trim(stdout)
  if success and out:sub(1, 1) == "/" and not out:find("\n") then
    pane:send_paste(out)
    return
  end

  local reason = out ~= "" and out or trim(stderr)
  if reason == "" then
    reason = "clip-image-send.ps1 が理由を出さずに失敗しました"
  end
  window:toast_notification(title, reason, nil, 6000)
end

return M
