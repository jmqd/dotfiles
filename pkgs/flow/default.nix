{
  lib,
  makeWrapper,
  rustPlatform,
  gitMinimal,
  zoekt,
}:
let
  zoektForFlow = zoekt.overrideAttrs (_: {
    pname = "zoekt-flow";
    subPackages = [
      "cmd/zoekt"
      "cmd/zoekt-git-index"
    ];
  });
in
rustPlatform.buildRustPackage rec {
  pname = "flow";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ gitMinimal ];

  postInstall = ''
    wrapProgram "$out/bin/flow" \
      --prefix PATH : ${
        lib.makeBinPath [
          gitMinimal
          zoektForFlow
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
