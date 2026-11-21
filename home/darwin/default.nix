{
  config,
  pkgs,
  ...
}:
let
  fakeBrew = pkgs.writeShellScriptBin "brew" ''
    echo "brew: this system is managed by Nix — install packages there instead." >&2
    exit 1
  '';
  geminiPackage = pkgs.callPackage ../../pkgs/gemini { };
  spotifyPackage = pkgs.callPackage ../../pkgs/spotify { };
  whatsappPackage = pkgs.callPackage ../../pkgs/whatsapp { };
in
{
  imports = [
    ../common.nix
    ./raycast.nix
    ./tailscale.nix
    ./retired-apps.nix
    ./wispr-flow.nix
    ./xcode.nix
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
    geminiPackage
    pkgs.orbstack
    spotifyPackage
    whatsappPackage
  ];
}
