# Pinned oh-my-pi release binary.
#
# Upstream source builds currently depend on a newer Bun than nixpkgs ships
# here, plus a nightly Rust toolchain for the native addon. The official GitHub
# release artifacts are single-file platform binaries, so this gives us a
# reproducible pin tied to an upstream tag with straightforward upgrades.
#
# To bump: update `version`, then refresh each platform hash with:
#   nix hash file --sri <downloaded-asset>
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  versionCheckHook,
  darwin,
}:
let
  version = "18.8.9";

  sources = {
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-HQhM+7lYf6H/dvp38G7oaAtqcPks0gf0p5QuK9Ra5mU=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-qj2g0pP9m2JCiEz4iWWq4nw3/SM+ExQ07kx2FZ9tgsU=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-xjnFewtiLL20i2KliWD0tqWzgBMAxFzA8bULCa1hRQs=";
    };
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-yswS1c3Ub/IH80UrNqDQz6fFuK7g1AOqg8WrH0a8y1g=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "omp: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "omp";
  inherit version;

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${finalAttrs.version}/${source.asset}";
    hash = source.hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs =
    lib.optionals stdenv.hostPlatform.isLinux [ patchelf ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.autoSignDarwinBinariesHook ];

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/omp
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --set-interpreter "$(< "$NIX_CC/nix-support/dynamic-linker")" "$out/bin/omp"
    ''}
    ln -s omp $out/bin/pi

    runHook postInstall
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Oh My Pi coding agent";
    homepage = "https://github.com/can1357/oh-my-pi";
    downloadPage = "https://github.com/can1357/oh-my-pi/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
