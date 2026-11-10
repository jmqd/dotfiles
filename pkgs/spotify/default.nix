# nixpkgs' Spotify lags upstream on Apple Silicon. The download URL never
# changes, so `flow pin bump spotify` reads the version from the DMG itself.
{
  lib,
  stdenv,
  fetchurl,
  spotify,
}:
let
  pin = lib.importJSON ../../pins/spotify.json;
  source = pin.sources.${stdenv.hostPlatform.system} or null;
in
if source == null then
  spotify
else
  spotify.overrideAttrs {
    inherit (pin) version;
    src = fetchurl {
      inherit (source) url hash;
    };
    # Generic fixup invalidates the vendor's Apple signature.
    dontFixup = true;
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      # Team 2FNC3A47ZF is Spotify. A valid signature from anyone else must fail.
      /usr/bin/codesign --verify --deep --strict \
        -R='anchor apple generic and certificate leaf[subject.OU] = "2FNC3A47ZF"' \
        "$out/Applications/Spotify.app"
      runHook postInstallCheck
    '';
  }
