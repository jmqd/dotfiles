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

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isElf [ autoPatchelfHook ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchShebangs = true;
  dontFixup = stdenvNoCC.hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/.unpack" "$out/bin"
    tar -xzf "$src" -C "$out/.unpack"
    mv "$out/.unpack/antigravity" "$out/bin/agy"
    chmod 0755 "$out/bin/agy"
    rm -rf "$out/.unpack"
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
