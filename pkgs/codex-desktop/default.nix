{
  fetchurl,
  lib,
  stdenvNoCC,
  unzip,
}:
let
  sources = {
    aarch64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.901.41600.zip";
      hash = "sha256-eJBi1Us5dw13ADV1g3OWOlYpl7J3/FqVfd8s0ar3aRM=";
    };
    x86_64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-26.901.41600.zip";
      hash = "sha256-jYTAiZOJhL7CdWgfeT+Pgu4ZRbP+mh1nYv29YyhJjNs=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "codex-desktop is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex-desktop";
  version = "26.901.41600";

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
