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
      /usr/bin/codesign --verify --deep --strict "$out/Applications/Spotify.app"
      runHook postInstallCheck
    '';
  }
