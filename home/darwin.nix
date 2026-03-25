{ pkgs, ... }:
{
  imports = [ ./common.nix ];

  # First set of macOS user packages managed by Home Manager.
  home.packages = with pkgs; [
    google-cloud-sdk
  ];
}
