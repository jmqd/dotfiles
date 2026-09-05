{
  lib,
  makeWrapper,
  rustPlatform,
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

  postInstall = ''
    wrapProgram "$out/bin/flow" \
      --prefix PATH : ${
        lib.makeBinPath [
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
