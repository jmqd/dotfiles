{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    googleworkspace-cli.url = "github:googleworkspace/cli/v0.3.5";
    trueflow.url = "git+file:///Users/jmq/src/trueflow";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      googleworkspace-cli,
      trueflow,
      home-manager,
      ...
    }:
    let
      mkGoogleworkspaceCliPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.rustPlatform.buildRustPackage {
          pname = "gws";
          version = "0.3.5";
          src = googleworkspace-cli;
          cargoLock.lockFile = "${googleworkspace-cli}/Cargo.lock";

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          meta = with pkgs.lib; {
            description = "Google Workspace CLI";
            homepage = "https://github.com/googleworkspace/cli";
            license = licenses.asl20;
            mainProgram = "gws";
            platforms = platforms.unix;
          };
        };

      mkTrueflowPkg =
        system:
        let
          packages = trueflow.packages.${system};
        in
        if packages ? native then packages.native else packages.default;

      mkPiPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.callPackage ./pkgs/pi { };

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;

          secretsLint = pkgs.writeShellApplication {
            name = "secrets-lint";
            runtimeInputs = [ pkgs.gitleaks ];
            text = ''
              set -euo pipefail
              exec gitleaks dir --redact --exit-code 1 --no-banner .
            '';
          };
        in
        {
          formatter = pkgs.nixfmt-rfc-style;

          devShells = {
            default = pkgs.mkShell {
              packages =
                (with pkgs; [
                  awscli2
                  git
                  gitleaks
                  python3
                  shellcheck
                  shfmt
                ])
                ++ [
                  googleworkspaceCliPkg
                  piPkg
                  trueflowPkg
                ];
            };

            # Use the same pinned Node/npm source as buildNpmPackage when
            # generating the package-local lockfile for pi.
            pi-packaging = pkgs.mkShell {
              packages = [ pkgs.nodejs ];
            };
          };

          packages = {
            pi = piPkg;
            secrets-lint = secretsLint;
          };

          apps = {
            pi = {
              type = "app";
              program = "${piPkg}/bin/pi";
            };
            secrets-lint = {
              type = "app";
              program = "${secretsLint}/bin/secrets-lint";
            };
          };
        }
      );

      mkHome = system: module:
        let
          pkgs = import nixpkgs { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            module
            (
              { ... }:
              {
                home.packages = [
                  googleworkspaceCliPkg
                  piPkg
                  trueflowPkg
                ];
              }
            )
          ];
        };
    in
    perSystem
    // {
      homeConfigurations = {
        "jmq@macos-aarch64" = mkHome "aarch64-darwin" ./home/hosts/jmq-macos.nix;
        "jmq@macos-x86_64" = mkHome "x86_64-darwin" ./home/hosts/jmq-macos.nix;
        "jmq@linux-aarch64" = mkHome "aarch64-linux" ./home/hosts/jmq-linux.nix;
        "jmq@linux-x86_64" = mkHome "x86_64-linux" ./home/hosts/jmq-linux.nix;
      };
    };
}
