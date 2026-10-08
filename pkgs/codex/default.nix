{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  gnutar,
  installShellFiles,
  makeBinaryWrapper,
  bubblewrap,
  ripgrep,
  installShellCompletions ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,
}:
let
  version = "0.161.0";
  assets = {
    "aarch64-darwin" = {
      binary = "codex-aarch64-apple-darwin";
      hash = "sha256-vYNHnzriFHTEB+whZPvCpj+nY/evu9Ej+2ppxSAc/Tg=";
    };
    "x86_64-darwin" = {
      binary = "codex-x86_64-apple-darwin";
      hash = "sha256-yz1yIlsV8HDqvxsONgIBTKi/Bn4g8R47c8iNt7JGOFM=";
    };
    "aarch64-linux" = {
      binary = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-XJC/S+PJf8Yvyvso7CM17jGObsszLh6O49LGOBSlomo=";
    };
    "x86_64-linux" = {
      binary = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-se+5UJdmDX8uWjiHYYoj8uobDVSAeL+SsPel0imgzvI=";
    };
  };
  system = stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "Codex prebuilt binary is unavailable for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/${asset.binary}.tar.gz";
    hash = asset.hash;
  };
  dontUnpack = true;

  nativeBuildInputs = [
    gnutar
    makeBinaryWrapper
  ]
  ++ lib.optional installShellCompletions installShellFiles;

  installPhase = ''
    runHook preInstall
    install -d "$out/bin"
    tar -xzf "$src" -C "$out/bin"
    mv "$out/bin/${asset.binary}" "$out/bin/codex"
    ${lib.optionalString installShellCompletions ''
      installShellCompletion --cmd codex \
        --bash <($out/bin/codex completion bash) \
        --fish <($out/bin/codex completion fish) \
        --zsh <($out/bin/codex completion zsh)
    ''}
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/codex" --prefix PATH : ${
      lib.makeBinPath ([ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ])
    }
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/codex" --version | grep -F "${version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    changelog = "https://github.com/openai/codex/releases/tag/rust-v${version}";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames assets;
  };
}
