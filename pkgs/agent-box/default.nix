{
  lib,
  makeBinaryWrapper,
  runCommand,
  rustPlatform,
  colima,
  curl,
  docker-client,
  gitMinimal,
  sops,
  # The dotfiles flake source. Sessions build their agents from it inside
  # the VM, so the binary is wrapped separately and only the wrapper changes
  # with each commit.
  flakeSource,
}:
let
  unwrapped = rustPlatform.buildRustPackage {
    pname = "agent-box-unwrapped";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./src
      ];
    };
    # The proxy tests push through it with real git and curl clients.
    nativeCheckInputs = [
      curl
      gitMinimal
    ];
    cargoLock.lockFile = ./Cargo.lock;

    meta.mainProgram = "agent-box";
  };
in
runCommand "agent-box-${unwrapped.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    passthru = { inherit unwrapped; };
    meta = {
      description = "Run coding agents on an untrusted GitHub repo in a scoped VM";
      homepage = "https://github.com/jmqd/dotfiles";
      license = lib.licenses.mit;
      mainProgram = "agent-box";
      platforms = lib.platforms.darwin;
    };
  }
  ''
    makeWrapper ${unwrapped}/bin/agent-box $out/bin/agent-box \
      --set AGENT_BOX_FLAKE ${flakeSource} \
      --prefix PATH : ${
        lib.makeBinPath [
          colima
          docker-client
          gitMinimal
          sops
        ]
      }
  ''
