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
  -- テキストのペーストは Ctrl+Shift+V (Linux 端末の慣例に合わせた)。
  -- 🔴 Ctrl+V は wezterm 側で握らないこと。herdr --remote の
  --    keys.remote_image_paste (既定 "ctrl+v") が生の Ctrl+V を受け取って、
  --    手元のクリップボード画像を develop 側の一時ファイルに渡し、
  --    そのパスをペインに入力する。wezterm が Ctrl+V を横取りすると
  --    herdr まで届かず、画像ペーストが無言で効かなくなる。
  {
    key = 'v',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.PasteFrom('Clipboard'),
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
  -- Ctrl+Shift+0 は Windows が入力言語の切り替えに使うことがある。
  { key = 'UpArrow', mods = 'CTRL|SHIFT', action = wezterm.action.IncreaseFontSize },
  { key = 'DownArrow', mods = 'CTRL|SHIFT', action = wezterm.action.DecreaseFontSize },
  { key = 'Home', mods = 'CTRL|SHIFT', action = wezterm.action.ResetFontSize },
}
