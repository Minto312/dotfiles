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
}
