{ pkgs, ... }:
let
  direnvPackage =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.direnv.overrideAttrs (old: {
        env = (old.env or { }) // {
          CGO_ENABLED = 1;
        };
      })
    else
      pkgs.direnv;
in
{
  programs.direnv = {
    enable = true;
    package = direnvPackage;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };
}
