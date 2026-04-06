{
  lib,
  makeWrapper,
  rustPlatform,
  git,
  zoekt,
}:
rustPlatform.buildRustPackage rec {
  pname = "flow";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram "$out/bin/flow" \
      --prefix PATH : ${lib.makeBinPath [ git zoekt ]}
  '';

  meta = with lib; {
    description = "jm.dev personal CLI";
    homepage = "https://github.com/jmqd/dotfiles";
    license = licenses.mit;
    mainProgram = "flow";
    platforms = platforms.unix;
  };
}
