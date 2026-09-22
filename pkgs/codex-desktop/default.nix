{
  fetchurl,
  lib,
  stdenvNoCC,
  unzip,
}:
let
  sources = {
    aarch64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.915.31945.zip";
      hash = "sha256-OtogFa6VpEyrghhiP7SjbJ1tRi1prmwmgngBASVBgMc=";
    };
    x86_64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-26.915.31945.zip";
      hash = "sha256-PAKi0TCAHxeNxLowcFl+xqyRU4M/o6hPA3f1wW7rduw=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "codex-desktop is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex-desktop";
  version = "26.915.31945";

  src = fetchurl source;

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  # Generic fixup rewrites bundled scripts and invalidates Apple's signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications"
    app_bundle="$(find . -maxdepth 1 -name '*.app' -type d -print -quit)"
    if [ -z "$app_bundle" ]; then
      echo "no .app bundle found in Codex ZIP" >&2
      exit 1
    fi
    cp -R "$app_bundle" "$out/Applications/Codex.app"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    /usr/bin/codesign --verify --deep --strict "$out/Applications/Codex.app"
    test -x "$out/Applications/Codex.app/Contents/MacOS/ChatGPT"
    runHook postInstallCheck
  '';

  meta = {
    description = "Codex desktop app";
    homepage = "https://developers.openai.com/codex/app";
    license = lib.licenses.unfree;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
