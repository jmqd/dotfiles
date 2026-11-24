{ pkgs, ... }:
{
  programs.direnv = {
    enable = true;
    package = pkgs.direnv;
    # Sourced from a build-time pre-generated script in home/zsh.nix.
    enableZshIntegration = false;
    nix-direnv.enable = true;
    config.global.hide_env_diff = true;
  };
}
