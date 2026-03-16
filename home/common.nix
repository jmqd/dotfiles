{ pkgs, ... }:
{
  imports = [
    ./direnv.nix
    ./git.nix
    ./ssh.nix
    ./tmux.nix
    ./wezterm.nix
    ./zsh.nix
  ];

  home.stateVersion = "25.05";
  programs.home-manager.enable = true;

  # Shared baseline tools available across platforms.
  home.packages = with pkgs; [
    fd
    git
    ripgrep
  ];
}
