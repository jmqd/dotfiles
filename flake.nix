{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    googleworkspace-cli.url = "github:googleworkspace/cli/v0.3.5";
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

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;

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

          devShells.default = pkgs.mkShell {
            packages =
              (with pkgs; [
                awscli2
                git
                gitleaks
                python3
                shellcheck
                shfmt
              ])
              ++ (if googleworkspaceCliPkg != null then [ googleworkspaceCliPkg ] else [ ]);
          };

          packages.secrets-lint = secretsLint;

          apps.secrets-lint = {
            type = "app";
            program = "${secretsLint}/bin/secrets-lint";
          };
        }
      );

      mkHome = system: module:
        let
          pkgs = import nixpkgs { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            module
            (
              { ... }:
              {
                home.packages = if googleworkspaceCliPkg != null then [ googleworkspaceCliPkg ] else [ ];
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
      };
    };
}
