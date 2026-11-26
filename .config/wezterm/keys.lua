local wezterm = require("wezterm")

return {
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local selection_text = window:get_selection_text_for_pane(pane)
      local is_selection_active = string.len(selection_text) ~= 0
      if is_selection_active then
        window:perform_action(wezterm.action.CopyTo('ClipboardAndPrimarySelection'), pane)
      else
        window:perform_action(wezterm.action.SendKey{ key='c', mods='CTRL' }, pane)
      end
    end),
  },
  -- テキストのペーストは Ctrl+V と Ctrl+Shift+V。
  -- Ctrl+V をそのまま送ると、Claude Code はクリップボードの画像を探しに行く
  -- (tmux 経由では手元の画像は見えない)。利用者の希望で、通常の貼り付けにした (2026-11-24)。
  -- ⚠ これで herdr --remote の画像の貼り付け (keys.remote_image_paste、既定 "ctrl+v") は効かなくなる。
  {
    key = 'v',
    mods = 'CTRL',
    action = wezterm.action.PasteFrom('Clipboard'),
  },
  {
    key = 'v',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.PasteFrom('Clipboard'),
  },
  -- 画像の貼り付けは Alt+V。手元のクリップボードの画像を develop に送り、そのパスを貼る (image_paste.lua)。
  -- ⚠ tmux のコピーモード (mode-keys emacs) の M-v (1 画面上へ) は届かなくなる。PageUp で代わりになる
  {
    key = 'v',
    mods = 'ALT',
    action = wezterm.action_callback(function(window, pane)
      require("image_paste").paste(window, pane)
    end),
  },
  -- Shift+Enter を Alt+Enter として送る (Claude Code の改行入力用)
  -- 端末は通常 Shift+Enter と Enter を区別しないため、別シーケンスに変換する
  {
    key = 'Enter',
    mods = 'SHIFT',
    action = wezterm.action.SendKey { key = 'Enter', mods = 'ALT' },
  },
  -- 文字の大きさを変える。disable_default_key_bindings で既定の Ctrl+= / Ctrl+- / Ctrl+0 は無効なので、ここで割り当てる。
  -- 既定のキーにしない理由: JIS 配列では = に Shift が要り、Ctrl+- (Ctrl+_) は Claude Code の入力欄の取り消しと重なる。
  { key = 'UpArrow', mods = 'CTRL', action = wezterm.action.IncreaseFontSize },
  { key = 'DownArrow', mods = 'CTRL', action = wezterm.action.DecreaseFontSize },
  { key = 'Home', mods = 'CTRL', action = wezterm.action.ResetFontSize },
}
