-- Pull in the wezterm API
local wezterm = require 'wezterm'

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices

-- For example, changing the color scheme:
config.color_scheme = 'PencilLight'

config.font = wezterm.font('Berkeley Mono')
config.font_size = 24.0

-- and finally, return the configuration to wezterm
return config
