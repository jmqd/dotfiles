# Gemini CLI from upstream's platform-independent JavaScript bundle. nixpkgs
# lags upstream's weekly releases and has marked its package for removal.
# Bump with `flow pin bump gemini-cli`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
  ripgrep,
  unzip,
  writableTmpDirAsHomeHook,
}:
let
  pin = lib.importJSON ../../pins/gemini-cli.json;
  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "gemini-cli is unsupported on ${stdenvNoCC.hostPlatform.system}");
  # The bundle looks for `rg-<os.platform()>-<os.arch()>` beside itself before
  # any `rg` on PATH, and accepts a PATH `rg` only from trusted system paths.
  nodePlatform = if stdenvNoCC.hostPlatform.isDarwin then "darwin" else "linux";
  nodeArch = if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "x64";
in
stdenvNoCC.mkDerivation {
  pname = "gemini-cli";
  inherit (pin) version;

  src = fetchurl source;

  nativeBuildInputs = [
    makeWrapper
    unzip
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    bundleDir="$out/lib/gemini"
    mkdir -p "$bundleDir"
    unzip -q "$src" -d "$bundleDir"

    # Self-update would try to rewrite the read-only store bundle. Chunk names
    # carry content hashes, so match by content and fail if the setting moved.
    patched=0
    for chunk in "$bundleDir"/chunk-*.js; do
      if grep -q 'enableAutoUpdate: {' "$chunk"; then
        sed -i '/enableAutoUpdate: {/,/}/ s/default: true/default: false/' "$chunk"
        patched=1
      fi
    done
    if [ "$patched" -ne 1 ]; then
      echo "gemini-cli: enableAutoUpdate setting not found; update the patch" >&2
      exit 1
    fi

    ln -s ${lib.getExe ripgrep} "$bundleDir/rg-${nodePlatform}-${nodeArch}"
    makeWrapper ${lib.getExe nodejs} "$out/bin/gemini" \
      --add-flags "--no-warnings=DEP0040" \
      --add-flags "$bundleDir/gemini.js"
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ writableTmpDirAsHomeHook ];
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/gemini" --version | grep -Fx ${lib.escapeShellArg pin.version}
    runHook postInstallCheck
  '';

  meta = {
    description = "Gemini agent for the terminal (pinned ahead of nixpkgs)";
    homepage = "https://github.com/google-gemini/gemini-cli";
    license = lib.licenses.asl20;
    mainProgram = "gemini";
    platforms = builtins.attrNames pin.sources;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
}
