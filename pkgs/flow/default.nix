{
  lib,
  makeWrapper,
  rustPlatform,
  _7zz,
  curl,
  gitMinimal,
  zoekt,
}:
rustPlatform.buildRustPackage rec {
  pname = "flow";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ gitMinimal ];

  # `flow pin` also runs the host's `nix`, which must match the daemon, so it
  # is deliberately not pinned here.
  postInstall = ''
    wrapProgram "$out/bin/flow" \
      --prefix PATH : ${
        lib.makeBinPath [
          _7zz
          curl
          gitMinimal
          zoekt
        ]
      }
  '';

  meta = with lib; {
    description = "jm.dev personal CLI";
    homepage = "https://github.com/jmqd/dotfiles";
    license = licenses.mit;
    mainProgram = "flow";
    platforms = platforms.unix;
  };
}
