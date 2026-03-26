{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    googleworkspace-cli.url = "github:googleworkspace/cli/v0.3.5";
    trueflow.url = "github:trueflow-dev/trueflow";
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

      mkHomePackagesModule =
        system:
        let
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
        in
        {
          ...
        }:
        {
          home.packages = [
            googleworkspaceCliPkg
            piPkg
            trueflowPkg
          ];
        };

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

      mkHome =
        {
          system,
          module,
          extraModules ? [ ],
        }:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            module
            (mkHomePackagesModule system)
          ] ++ extraModules;
        };

      mkMacosHome = system:
        let
          bootstrapUser =
            let
              explicitUser = builtins.getEnv "HM_BOOTSTRAP_USER";
              envUser = builtins.getEnv "USER";
            in
            if explicitUser != "" then explicitUser else if envUser != "" then envUser else "jmq";
          bootstrapHome =
            let envHome = builtins.getEnv "HOME";
            in
            if envHome != "" then envHome else "/Users/${bootstrapUser}";
        in
        mkHome {
          inherit system;
          module = ./home/hosts/jmq-macos.nix;
          extraModules = [
            {
              home.username = nixpkgs.lib.mkForce bootstrapUser;
              home.homeDirectory = nixpkgs.lib.mkForce bootstrapHome;
            }
          ];
        };

      mkNixosHost =
        {
          system,
          hostModule,
          homeModule,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            hostModule
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.users.jmq = {
                ...
              }:
              {
                imports = [
                  homeModule
                  (mkHomePackagesModule system)
                ];
              };
            }
          ];
        };
    in
    perSystem
    // {
      homeConfigurations = {
        "macos-aarch64" = mkMacosHome "aarch64-darwin";
        "macos-x86_64" = mkMacosHome "x86_64-darwin";
        "linux-aarch64" = mkHome {
          system = "aarch64-linux";
          module = ./home/hosts/jmq-linux.nix;
        };
        "linux-x86_64" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
        };
      };

      nixosConfigurations = {
        jmws = mkNixosHost {
          system = "x86_64-linux";
          hostModule = ./nixos/hosts/jmws.nix;
          homeModule = ./home/hosts/jmq-linux.nix;
        };
      };
    };
}
