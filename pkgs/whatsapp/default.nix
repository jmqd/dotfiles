# nixpkgs lags upstream's Sparkle feed
# (https://web.whatsapp.com/desktop/mac_native/updates/?branch=master&configuration=Release).
# Bump with `flow pin bump whatsapp`.
{
  lib,
  stdenv,
  fetchzip,
  whatsapp-for-mac,
}:
let
  pin = lib.importJSON ../../pins/whatsapp.json;
  source =
    pin.sources.${stdenv.hostPlatform.system}
      or (throw "whatsapp is unsupported on ${stdenv.hostPlatform.system}");
in
whatsapp-for-mac.overrideAttrs {
  inherit (pin) version;
  src = fetchzip {
    extension = "zip";
    name = "WhatsApp.app";
    inherit (source) url hash;
  };
  # Generic fixup invalidates the vendor's Apple signature.
  dontFixup = true;
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # Team 57T9237FN3 is WhatsApp. A valid signature from anyone else must fail.
    /usr/bin/codesign --verify --deep --strict \
      -R='anchor apple generic and certificate leaf[subject.OU] = "57T9237FN3"' \
      "$out/Applications/WhatsApp.app"
    runHook postInstallCheck
  '';
}
