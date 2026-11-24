# Pinned oh-my-pi release binary.
#
# Upstream source builds currently depend on a newer Bun than nixpkgs ships
# here, plus a nightly Rust toolchain for the native addon. The official GitHub
# release artifacts are single-file platform binaries, so this gives us a
# reproducible pin tied to an upstream tag with straightforward upgrades.
#
# pins/omp.json holds each platform's release asset. Bump it with
# `flow pin bump omp`.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  patchelf,
  versionCheckHook,
  darwin,
}:
let
  pin = lib.importJSON ../../pins/omp.json;
  inherit (pin) version;

  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "omp: unsupported platform ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "omp";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchShebangs = true;

  nativeBuildInputs =
    lib.optionals stdenvNoCC.hostPlatform.isLinux [ patchelf ]
    ++ lib.optionals stdenvNoCC.hostPlatform.isDarwin [ darwin.autoSignDarwinBinariesHook ];

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/omp
    ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
      patchelf --set-interpreter "${stdenv.cc.bintools.dynamicLinker}" "$out/bin/omp"
    ''}
    ln -s omp $out/bin/pi

    runHook postInstall
  '';

  doInstallCheck = stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Oh My Pi coding agent";
    homepage = "https://github.com/can1357/oh-my-pi";
    downloadPage = "https://github.com/can1357/oh-my-pi/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames pin.sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
