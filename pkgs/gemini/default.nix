# Google's Gemini app for macOS; nixpkgs does not package it. The download URL
# never changes, so `flow pin bump gemini` reads the version from the DMG.
{
  fetchurl,
  lib,
  stdenvNoCC,
  undmg,
}:
let
  pin = lib.importJSON ../../pins/gemini.json;
  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "gemini is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "gemini";
  inherit (pin) version;

  src = fetchurl source;

  nativeBuildInputs = [ undmg ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Generic fixup invalidates the vendor's Apple signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/.unpack" "$out/Applications"
    (
      cd "$out/.unpack"
      undmg "$src"
    )
    mv "$out/.unpack/Gemini.app" "$out/Applications/Gemini.app"
    rm -rf "$out/.unpack"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # Team EQHXZ8M8AV is Google. A valid signature from anyone else must fail.
    /usr/bin/codesign --verify --deep --strict \
      -R='anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV"' \
      "$out/Applications/Gemini.app"
    runHook postInstallCheck
  '';

  meta = {
    description = "Google Gemini app for macOS";
    homepage = "https://gemini.google/mac";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
