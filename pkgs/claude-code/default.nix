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
  version = "2.1.219";

  # `claude` ships as a self-contained native executable in a per-platform
  # package. `hash` is the npm `dist.integrity` of that package's tarball.
  sources = {
    "aarch64-darwin" = {
      plat = "darwin-arm64";
      hash = "sha512-/t/JlmaHh6vtXbZ0R8iRnSBzhc1OSQLybS8HB5RA/BtbueODKQKvtCiCBVwdXXjmdn3aBFrmWRbGzpYZRVcZtw==";
    };
    "x86_64-darwin" = {
      plat = "darwin-x64";
      hash = "sha512-+xuRyR76Q4ZtorDuZVaTvfFEKunCsthZxR+c8/cHtvViaYt4cZ11Aof2GYH0qQhyY5DaoQphO21Lnr/VfzpGqQ==";
    };
    "aarch64-linux" = {
      plat = "linux-arm64";
      hash = "sha512-G5yLidk2u6djL5PPuBYXVwVhTsZY5zLoZwh1Jnrd/IRyYb0P0x4gKTzVvGlsGepkBrOp0H2k/KuicyNPrXt57Q==";
    };
    "x86_64-linux" = {
      plat = "linux-x64";
      hash = "sha512-Eq8aJpMrfy5rwQZQys/MdDD5Ph96ugZMgmwZmo4mXveEvp7JTZX8vUvqN/sHBn/yVmhzJNWcvepzQuBkcrLXZw==";
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

  # Bun's compiled executable carries the Claude application in ELF sections;
  # stripping it makes the binary fall back to Bun's own CLI.
  dontStrip = true;
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
