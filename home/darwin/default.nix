{ pkgs, ... }:
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

  # First set of macOS user packages managed by Home Manager.
  home.packages = with pkgs; [
    google-cloud-sdk
  ];
}
