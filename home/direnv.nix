{ pkgs, ... }:
let
  direnvPackage =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.direnv.overrideAttrs (old: {
        # The upstream direnv test suite can hang on Darwin in Nix builds
        # (observed stuck in `make test-go test-bash test-fish test-zsh`).
        doCheck = false;
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
