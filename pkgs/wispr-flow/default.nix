{
  fetchurl,
  lib,
  stdenvNoCC,
  undmg,
}:
let
  version = "1.6.957";
  sources = {
    aarch64-darwin = {
      url = "https://dl.wisprflow.com/wispr-flow/darwin/arm64/dmgs/Flow-v${version}.dmg";
      hash = "sha256-UAhR6IVMwqqNHNypWGJSF61lEsKbrvCcBaFgZwkGEMs=";
    };
    x86_64-darwin = {
      url = "https://dl.wisprflow.com/wispr-flow/darwin/x64/dmgs/Flow-v${version}.dmg";
      hash = "sha256-BC9Rp5K7Xq5XDqMvZc5/qEZrcqpvpF70aeWMcO3OVzg=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
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
