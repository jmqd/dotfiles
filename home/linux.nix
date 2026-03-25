{ lib, pkgs, ... }:
{
  imports = [
    ./common.nix
    ./linux-desktop.nix
  ];

  nixpkgs.config.allowUnfree = true;

  home.sessionVariables = {
    TERMINAL = "wezterm";
    VISUAL = "emacsclient -c";
  };

  home.shellAliases = {
    top = "btm";
  };

  home.packages =
    (with pkgs; [
      autorandr
      awscli2
      dmenu
      flameshot
      i3lock
      i3wsr
      imagemagick
      killall
      nixfmt
      pandoc
      pavucontrol
      pmutils
      quickemu
      shellcheck
      shfmt
      unzip
      xclip
      xdotool
      xwininfo
      zip
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 (with pkgs; [
      discord
      lutris
      slack
      spotify
      virt-manager
      virt-viewer
    ]);

  programs = {
    chromium.enable = true;
    google-chrome.enable = pkgs.stdenv.hostPlatform.isx86_64;
    rofi.enable = true;

    nix-index = {
      enable = true;
      enableZshIntegration = true;
    };

    emacs = {
      enable = true;
      package = pkgs.emacs;
    };

    i3status-rust.enable = true;
  };

  services.emacs = {
    enable = true;
    package = pkgs.emacs;
  };
}
