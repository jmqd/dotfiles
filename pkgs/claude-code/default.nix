# Manually pinned claude-code, mirroring how pi is pinned. nixpkgs lags behind
# upstream, so we fetch the platform-specific native binary directly from npm.
#
# To bump: set `version`, then update each platform `hash` to the npm `integrity`
# field (already SRI sha512), e.g.
#   curl -s https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/<version> \
#     | jq -r .dist.integrity
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  procps,
  bubblewrap,
  socat,
}:
let
  version = "2.1.195";

  # `claude` ships as a self-contained native executable in a per-platform
  # package. `hash` is the npm `dist.integrity` of that package's tarball.
  sources = {
    "aarch64-darwin" = {
      plat = "darwin-arm64";
      hash = "sha512-x1H5ABaWgs97DCe3yzuxFvqaCescJJVyWE8miWthklQvp9R+PeTWrlgXtj3rbNszqkgmwINQ9Fg8y/qZT6oYHA==";
    };
    "x86_64-darwin" = {
      plat = "darwin-x64";
      hash = "sha512-PToVqTlvhXyJW+Xb2W8gokr0gFI4zbMv+jXq4dvQP/VQVOS5lF6MwLUPjhAyhpcsxr3+f+qq2792oyTxcq5iZA==";
    };
    "aarch64-linux" = {
      plat = "linux-arm64";
      hash = "sha512-/K1XESsZw40q9dUzK2trHPDDq7hwKoxkyj6CAn1mpPy54jjMEfO/fgCjN/Ek1W0H2nzy2I6jkshl/e+zC11Z0g==";
    };
    "x86_64-linux" = {
      plat = "linux-x64";
      hash = "sha512-EqF+Ws50rRnfJg7LIAbWbsyAMkzC8jPNVHPUlvoEk1UCjA8x3POFCgADK0IHjWEIcIp7a7lgQtYbYrb+5cH1WQ==";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "claude-code: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-${source.plat}/-/claude-code-${source.plat}-${finalAttrs.version}.tgz";
    hash = source.hash;
  };

  sourceRoot = "package";

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 claude $out/bin/claude
    runHook postInstall
  '';

  # `claude-code` tries to auto-update by default, this disables that
  # functionality. procps provides pgrep (darwin) / ps (linux) for the
  # node-tree-kill dependency; bubblewrap and socat back the Linux sandbox.
  postInstall = ''
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --prefix PATH : ${
        lib.makeBinPath (
          [ procps ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            bubblewrap
            socat
          ]
        )
      }
  '';

  meta = {
    description = "Agentic coding tool that lives in your terminal (manually pinned ahead of nixpkgs)";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = lib.licenses.unfree;
    mainProgram = "claude";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
