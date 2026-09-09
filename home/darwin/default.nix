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
        version = "1.2.99.317";
        # The CDN URL moves; verify the bundle version before refreshing the hash.
        src = pkgs.fetchurl {
          url = "https://download.scdn.co/SpotifyARM64.dmg";
          hash = "sha256-xF6OoHAMNvvDCdY1G4A+n2zuHb+GWjCqb6PYy50HILE=";
        };
        # Generic fixup invalidates the vendor's Apple signature.
        dontFixup = true;
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          /usr/bin/codesign --verify --deep --strict "$out/Applications/Spotify.app"
          runHook postInstallCheck
        '';
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
