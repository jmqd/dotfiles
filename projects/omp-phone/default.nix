{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
  cacert,
}:
rustPlatform.buildRustPackage {
  pname = "omp-phone";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      let
        name = baseNameOf path;
      in
      !(builtins.elem name [
        "target"
        "node_modules"
        ".git"
      ])
      # Extension tests run as a flake check and are not part of the installed extension.
      && !(lib.hasSuffix ".test.ts" name);
  };
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];
  preCheck = ''
    # Enrollment checks state ownership against HOME; Nix's default HOME is absent.
    export HOME="$(mktemp -d)"
    # The push client's native TLS roots are absent from the Linux build sandbox.
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
  '';
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
