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
}:
let
  version = "16.2.5";

  sources = {
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-XNSShbb9zprWmP0I4MlGuIWqSb7FEo745eUO0J3OYXs=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-+mBMJwXNlEtK+cKqxWYQ2XQRirlzyeBLoxvaz9ohnNk=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-jDIl+iKK1mq0YVzDwGZhOaggQU+HhQSmxJeNRrVijoc=";
    };
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-VBcgW9727OIi6/vWyqQuDvouNRdpKngApe2itHCEdg0=";
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

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ patchelf ];

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
