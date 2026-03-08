{ pkgs, ... }:
{
  imports = [ ./common.nix ];

  home.username = "jmq";
  home.homeDirectory = "/Users/jmq";

  # First set of macOS user packages managed by Home Manager.
  home.packages = with pkgs; [
    google-cloud-sdk
    jq
  ];
}
