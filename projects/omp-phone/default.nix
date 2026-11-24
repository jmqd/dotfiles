{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
  aws-lc,
  cacert,
  runCommandLocal,
  symlinkJoin,
}:
let
  pname = "omp-phone";
  version = "0.1.0";

  # Keep the Rust build strictly scoped to files Cargo compiles (including
  # web/* embedded via include_str!). Edits to extension/, home-module.nix, or
  # package metadata will not trigger a Rust rebuild.
  bin = rustPlatform.buildRustPackage {
    inherit pname version;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./src
        ./web
      ];
    };
    cargoLock.lockFile = ./Cargo.lock;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      aws-lc
      openssl
    ];
    preCheck = ''
      # Enrollment checks state ownership against HOME; Nix's default HOME is absent.
      export HOME="$(mktemp -d)"
      # The push client's native TLS roots are absent from the Linux build sandbox.
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    '';

    meta = {
      description = "Private phone access to live Oh My Pi sessions";
      mainProgram = "omp-phone";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };

  # Extension tests run as a flake check and are not part of the installed extension.
  assetsSrc = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (file: !(lib.hasSuffix ".test.ts" file.name)) ./extension)
      ./package.json
      ./LICENSE
    ];
  };

  assets = runCommandLocal "${pname}-assets-${version}" { } ''
    mkdir -p "$out/share/omp-phone"
    cp -R ${assetsSrc}/. "$out/share/omp-phone/"
  '';
in
symlinkJoin {
  name = "${pname}-${version}";
  inherit pname version;
  paths = [
    bin
    assets
  ];
  passthru = {
    inherit bin assets;
  };
  inherit (bin) meta;
}
