{ pkgs, ... }:
{
  programs.direnv = {
    enable = true;
    package = pkgs.direnv;
    enableZshIntegration = true;
    nix-direnv.enable = true;
    config.global.hide_env_diff = true;
  };
}
