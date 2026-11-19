# Manually pinned Antigravity CLI. nixpkgs lags behind upstream, so we fetch
# the platform tarball from the GitHub release directly.
#
# pins/antigravity-cli.json holds each platform's release asset and hash. Bump
# it with `flow pin bump antigravity-cli`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}:
let
  pin = lib.importJSON ../../pins/antigravity-cli.json;
  inherit (pin) version;

  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "antigravity-cli: unsupported platform ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "antigravity-cli";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  sourceRoot = ".";

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isElf [ autoPatchelfHook ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 antigravity $out/bin/agy
    runHook postInstall
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "Google's Antigravity terminal agent client (manually pinned ahead of nixpkgs)";
    homepage = "https://antigravity.google";
    downloadPage = "https://github.com/google-antigravity/antigravity-cli/releases";
    license = lib.licenses.unfree;
    mainProgram = "agy";
    platforms = builtins.attrNames pin.sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
