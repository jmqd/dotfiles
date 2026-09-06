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
  spotifyPackage =
    if pkgs.stdenv.hostPlatform.system == "aarch64-darwin" then
      pkgs.spotify.overrideAttrs {
        # Nixpkgs pins this exact release through the Wayback Machine. The
        # official CDN currently serves the same fixed-output artifact, so use
        # it as a fallback when the archive responds with HTTP 429.
        src = pkgs.fetchurl {
          urls = [
            "https://web.archive.org/web/20260829115632/https://download.scdn.co/SpotifyARM64.dmg"
            "https://download.scdn.co/SpotifyARM64.dmg"
          ];
          hash = "sha256-iFLqFQXKPkeCHfzB6hshbZDWjumKN2u4Bj7lvl8waUY=";
        };
      }
    else
      pkgs.spotify;
in
{
  imports = [
    ../common.nix
    ./raycast.nix
    ./tailscale.nix
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
    spotifyPackage
  ];
}
