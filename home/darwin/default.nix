{ config, pkgs, ... }:
let
  fakeBrew = pkgs.writeShellScriptBin "brew" ''
    echo "brew: this system is managed by Nix — install packages there instead." >&2
    exit 1
  '';
  orbstackPackage =
    if pkgs.stdenv.hostPlatform.system == "x86_64-darwin" then
      pkgs.orbstack.overrideAttrs {
        version = "2.2.3-20963";
        src = pkgs.fetchurl {
          url = "https://cdn-updates.orbstack.dev/amd64/OrbStack_v2.2.3_20963_amd64.dmg";
          hash = "sha256-0aqHI9Gaa8jbpLZJDplxDpJqpfIpkg2o4b4Pu6kDZB8=";
        };
      }
    else
      pkgs.orbstack;
in
{
  imports = [
    ../common.nix
    ./raycast.nix
  ];

  targets.darwin = {
    copyApps.enable = true;
    linkApps.enable = false;
  };

  home.file."Applications/Screen Sharing.app".source =
    config.lib.file.mkOutOfStoreSymlink "/System/Applications/Utilities/Screen Sharing.app";

  # First set of macOS user packages managed by Home Manager.
  home.packages = [
    fakeBrew
    pkgs.google-cloud-sdk
    orbstackPackage
    pkgs.spotify
  ];
}
