{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jmq.linux;
in
{
  imports = [
    ./common.nix
    ./linux-desktop.nix
  ];

  options.jmq.linux = {
    desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install Linux desktop packages and desktop integrations.";
    };

    heavyweightApps.enable = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.hostPlatform.isx86_64;
      description = "Install large GUI applications that dominate fresh-machine downloads.";
    };
  };

  config = {
    home.sessionVariables = {
      TERMINAL = "wezterm";
    };

    home.shellAliases = {
      top = "btm";
    };

    home.packages =
      (with pkgs; [
        killall
        nixfmt
      ])
      ++ lib.optionals cfg.desktop.enable (
        with pkgs;
        [
          autorandr
          dmenu
          flameshot
          geeqie
          i3lock
          i3wsr
          pavucontrol
          pmutils
          quickemu
          xclip
          xdotool
          ydotool
          xwininfo
        ]
      )
      ++ lib.optionals (cfg.desktop.enable && cfg.heavyweightApps.enable) (
        with pkgs;
        [
          discord
          lutris
          slack
          spotify
          virt-manager
          virt-viewer
        ]
      );

    programs = {
      chromium.enable = cfg.desktop.enable;
      google-chrome.enable = cfg.desktop.enable && pkgs.stdenv.hostPlatform.isx86_64;
      rofi.enable = cfg.desktop.enable;

      nix-index = {
        enable = true;
        enableZshIntegration = true;
      };

      i3status-rust.enable = cfg.desktop.enable;
    };
  };
}
