{
  fetchurl,
  lib,
  stdenvNoCC,
  undmg,
}:
let
  # Bump with `flow pin bump wispr-flow`.
  pin = lib.importJSON ../../pins/wispr-flow.json;
  inherit (pin) version;
  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "wispr-flow is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "wispr-flow";
  inherit version;

  src = fetchurl source;

  nativeBuildInputs = [ undmg ];
  sourceRoot = ".";

  # Generic fixup rewrites bundled scripts and invalidates Apple's signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications"
    cp -R "Wispr Flow.app" "$out/Applications/"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    app="$out/Applications/Wispr Flow.app"
    /usr/bin/codesign --verify --deep --strict "$app"
    test -x "$app/Contents/MacOS/Wispr Flow"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "${version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Wispr Flow voice dictation app";
    homepage = "https://wisprflow.ai";
    license = lib.licenses.unfree;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
