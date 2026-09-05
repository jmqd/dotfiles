{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
}:
rustPlatform.buildRustPackage {
  pname = "omp-phone";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      !(builtins.elem (baseNameOf path) [
        "target"
        "node_modules"
        ".git"
      ]);
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];
  postInstall = ''
    mkdir -p $out/share/omp-phone
    cp -R extension package.json LICENSE $out/share/omp-phone/
  '';

  meta = {
    description = "Private phone access to live Oh My Pi sessions";
    mainProgram = "omp-phone";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
