{
  fetchurl,
  lib,
  stdenvNoCC,
  undmg,
}:
let
  sources = {
    aarch64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";
      hash = "sha256-7+3GyP+o+Ued3e0/7UDFytJhx3m3mP3RYYR/SBQZhcI=";
    };
    x86_64-darwin = {
      url = "https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg";
      hash = "sha256-tPv6V5PP4cU5H489+myQh9ZgAe6XTN4I0tigPmmzmwU=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "codex-desktop is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex-desktop";
  version = "26.616.71553";

  src = fetchurl source;

  nativeBuildInputs = [ undmg ];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications"
    app_bundle="$(find . -maxdepth 1 -name '*.app' -type d -print -quit)"
    if [ -z "$app_bundle" ]; then
      echo "no .app bundle found in Codex DMG" >&2
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
  };
}
