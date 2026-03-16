{ lib, pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        addKeysToAgent = "yes";
        identityFile = [ "~/.ssh/id_ed25519" ];
        extraOptions = lib.optionalAttrs pkgs.stdenv.isDarwin {
          UseKeychain = "yes";
        };
      };
    };
  };
}
