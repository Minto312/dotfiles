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
  {
    key = 'v',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      window:perform_action(wezterm.action.PasteFrom('Clipboard'), pane)
    end),
  },
  -- Shift+Enter を Alt+Enter として送る (Claude Code の改行入力用)
  -- 端末は通常 Shift+Enter と Enter を区別しないため、別シーケンスに変換する
  {
    key = 'Enter',
    mods = 'SHIFT',
    action = wezterm.action.SendKey { key = 'Enter', mods = 'ALT' },
  },
}
