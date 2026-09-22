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
  perl,
  versionCheckHook,
  darwin,
}:
let
  version = "18.2.8";

  sources = {
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-z400p/5vYN4ay+dPKcggJuTAeIjp2J9+vO65IhWeV4c=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-s4XCu6zdwJsmbsGbqV67KIIwEpPUk5DX/TLMOhKh2kE=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-qapj5DyVzKoGg+n+0DRjxAGCniIK0rvEFLNB0tSeWAY=";
    };
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-sMAdpzOdh/1dJtf6p7YcExpQZIOZlieDiZ/ZOm2LHWU=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "omp: unsupported platform ${stdenv.hostPlatform.system}");

  # Stopgap for 18.2.8 only. That release hardcodes the Claude Code version it
  # reports to Anthropic as 2.1.257, and newer models (Opus 5.5) reject anything
  # below 2.1.280 with `claude_code_version_too_old`. Upstream fixed this in
  # v18.2.9 (commit 2282226, dynamic versioning + PI_AI_CLAUDE_CODE_VERSION),
  # so the patch is gated on the exact version and drops out on the next bump.
  claudeCodeVersionPatch = {
    appliesTo = "18.2.8";
    from = "2.1.257";
    to = "2.1.280";
    expectedOccurrences = 2;
  };
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

  nativeBuildInputs = [
    perl
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ patchelf ]
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

  postInstall = lib.optionalString (finalAttrs.version == claudeCodeVersionPatch.appliesTo) ''
    export from='${claudeCodeVersionPatch.from}'
    export to='${claudeCodeVersionPatch.to}'
    count="$(grep -a -o -F "$from" "$out/bin/omp" | wc -l | tr -d ' ')"
    if [ "$count" != "${toString claudeCodeVersionPatch.expectedOccurrences}" ]; then
      echo "omp: expected ${toString claudeCodeVersionPatch.expectedOccurrences} occurrences of $from, found $count" >&2
      exit 1
    fi
    if [ "''${#from}" != "''${#to}" ]; then
      echo "omp: replacement must be the same length as the original" >&2
      exit 1
    fi
    chmod u+w "$out/bin/omp"
    perl -pi -e 'BEGIN { binmode STDIN; binmode STDOUT } s/\Q$ENV{from}\E/$ENV{to}/g' "$out/bin/omp"
    chmod u-w "$out/bin/omp"
    echo "omp: patched reported Claude Code version $from -> $to"
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
