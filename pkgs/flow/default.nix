{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage rec {
  pname = "flow";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  meta = with lib; {
    description = "jm.dev personal CLI";
    homepage = "https://github.com/jmqd/dotfiles";
    license = licenses.mit;
    mainProgram = "flow";
    platforms = platforms.unix;
  };
}
