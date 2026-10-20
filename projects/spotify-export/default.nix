{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "spotify-export";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: !(builtins.elem (baseNameOf path) [ "target" ]);
  };
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Export a Spotify playlist's track metadata as TSV";
    mainProgram = "spotify-export";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
