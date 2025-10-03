-- keybinds.lua
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

  {
    key = 't',
    mods = 'CTRL',
    action = wezterm.action.SpawnTab 'CurrentPaneDomain',
  },
  {
    key = '\'',
    mods = 'CTRL',
    action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' },
  },

  { 
    key = 'w',
    mods = 'CTRL',
    action = wezterm.action.PaneSelect {
      mode = 'Activate',
    },
  },
  {
    key = 'g',
    mods = 'CTRL',
    action = wezterm.action.PaneSelect {
      mode = 'SwapWithActive',
    },
  },

}
