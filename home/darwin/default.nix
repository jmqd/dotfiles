{ config, pkgs, ... }:
let
  fakeBrew = pkgs.writeShellScriptBin "brew" ''
    echo "brew: this system is managed by Nix — install packages there instead." >&2
    exit 1
  '';
in
{
  imports = [
    ../common.nix
    ./aerospace.nix
    ./raycast.nix
  ];

  targets.darwin = {
    copyApps.enable = false;
    linkApps.enable = true;
  };

  home.file."Applications/Screen Sharing.app".source =
    config.lib.file.mkOutOfStoreSymlink "/System/Library/CoreServices/Applications/Screen Sharing.app";

  # First set of macOS user packages managed by Home Manager.
  home.packages = [
    fakeBrew
    pkgs.google-cloud-sdk
    pkgs.orbstack
    pkgs.spotify
  ];
}
