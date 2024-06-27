-- Pull in the wezterm API
local wezterm = require 'wezterm'

-- This will hold the configuration.
local config = wezterm.config_builder()

-- Custom config below --

config.color_scheme = 'PencilLight'
config.font = wezterm.font('Berkeley Mono')
config.font_size = 24.0
config.tab_bar_at_bottom = true
config.use_fancy_tab_bar = false

return config
