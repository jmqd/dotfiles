{ pkgs, ... }:
{
  imports = [
    ../common.nix
    ./aerospace.nix
  ];

  targets.darwin = {
    copyApps.enable = true;
    linkApps.enable = false;
  };

  # First set of macOS user packages managed by Home Manager.
  home.packages = with pkgs; [
    google-cloud-sdk
  ];
}
