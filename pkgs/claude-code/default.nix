# Manually pinned claude-code, mirroring how pi is pinned. nixpkgs lags behind
# upstream, so we fetch the platform-specific native binary directly from npm.
#
# pins/claude-code.json holds each platform package's npm tarball and its
# `dist.integrity` (already SRI sha512). Bump it with `flow pin bump claude-code`.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  procps,
  bubblewrap,
  socat,
}:
let
  pin = lib.importJSON ../../pins/claude-code.json;
  inherit (pin) version;

  # `claude` ships as a self-contained native executable in a per-platform
  # package.
  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "claude-code: unsupported platform ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # Bun's compiled executable carries the Claude application in ELF sections;
  # stripping it makes the binary fall back to Bun's own CLI.
  dontStrip = true;
  dontPatchShebangs = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/.unpack" "$out/bin"
    tar -xzf "$src" -C "$out/.unpack"
    mv "$out/.unpack/package/claude" "$out/bin/claude"
    chmod 0755 "$out/bin/claude"
    rm -rf "$out/.unpack"
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
          ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [
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
    platforms = builtins.attrNames pin.sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
