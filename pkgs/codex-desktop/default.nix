{
  fetchurl,
  lib,
  stdenvNoCC,
  unzip,
}:
let
  sources = {
    aarch64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.623.141536.zip";
      hash = "sha256-2UjcNrg1j1opJLAz+/CDmO6nhg3J6Xy1q5s1RJAoOgo=";
    };
    x86_64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-x64-26.623.141536.zip";
      hash = "sha256-Wo65vKDAIbmU5WyT7zUCvbwQWXW8uD+ZrvQPKuVtSMw=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "codex-desktop is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex-desktop";
  version = "26.623.141536";

  src = fetchurl source;

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

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
