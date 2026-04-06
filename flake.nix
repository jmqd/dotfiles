{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    googleworkspace-cli.url = "github:googleworkspace/cli/v0.3.5";
    notion-cli = {
      url = "github:lox/notion-cli/v0.5.0";
      flake = false;
    };
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
      notion-cli,
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

      mkNotionCliPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.buildGoModule {
          pname = "notion-cli";
          version = "0.5.0";
          src = notion-cli;
          vendorHash = "sha256-SXs/voGAlA66aGMUC6GzttSejo9kSSOVdujp5Nl9GZM=";

          ldflags = [
            "-X main.version=v0.5.0"
          ];

          meta = with pkgs.lib; {
            description = "Notion CLI";
            homepage = "https://github.com/lox/notion-cli";
            license = licenses.mit;
            mainProgram = "notion-cli";
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

      mkFlowPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.callPackage ./pkgs/flow { };

      mkHomePackagesModule =
        system:
        let
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          flowPkg = mkFlowPkg system;
        in
        {
          ...
        }:
        {
          home.packages = [
            flowPkg
            googleworkspaceCliPkg
            notionCliPkg
            piPkg
            trueflowPkg
          ];
        };

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          flowPkg = mkFlowPkg system;

          shellScriptFiles = [
            "bin/bootstrap-macos.sh"
            "bin/bootstrap-rust.sh"
            "bin/hm-switch.sh"
            "bin/link-private-data.sh"
            "bin/lint-secrets.sh"
            "bin/setup-git-hooks.sh"
            "tests/flow-search-smoke.sh"
            "tests/hive-smoke.sh"
          ];

          shellcheckCheck = pkgs.runCommand "shellcheck-bin-scripts" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            cd ${./.}
            shellcheck ${pkgs.lib.escapeShellArgs shellScriptFiles}
            touch $out
          '';

          shfmtCheck = pkgs.runCommand "shfmt-bin-scripts" {
            nativeBuildInputs = [ pkgs.shfmt ];
          } ''
            cd ${./.}
            shfmt -d ${pkgs.lib.escapeShellArgs shellScriptFiles}
            touch $out
          '';

          reviewOrchestratorTests = pkgs.runCommand "review-orchestrator-tests" {
            nativeBuildInputs = [ pkgs.nodejs ];
          } ''
            cd ${./.}
            node --test home/.pi/agent/extensions/review-orchestrator/core.test.ts
            touch $out
          '';

          hiveSmokeTests = pkgs.runCommand "hive-smoke-tests" {
            nativeBuildInputs = [ pkgs.bash ];
          } ''
            cd ${./.}
            bash tests/hive-smoke.sh
            touch $out
          '';

          flowSmokeTests = pkgs.runCommand "flow-smoke-tests" {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.git
              pkgs.jq
              flowPkg
            ];
          } ''
            cd ${./.}
            bash tests/flow-search-smoke.sh
            touch $out
          '';

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
            flow = flowPkg;
            notion-cli = notionCliPkg;
            pi = piPkg;
            secrets-lint = secretsLint;
          };

          checks = {
            flow = flowPkg;
            flow-smoke-tests = flowSmokeTests;
            hive-smoke-tests = hiveSmokeTests;
            review-orchestrator-tests = reviewOrchestratorTests;
            shellcheck-bin-scripts = shellcheckCheck;
            shfmt-bin-scripts = shfmtCheck;
          };

          apps = {
            flow = {
              type = "app";
              program = "${flowPkg}/bin/flow";
            };
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
          nixpkgsConfig ? { },
        }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = nixpkgsConfig;
          };
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
          nixpkgsConfig = {
            allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [
              "berkley-mono"
              "orbstack"
              "raycast"
              "spotify"
            ];
          };
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
          nixpkgsConfig.allowUnfree = true;
        };
        "linux-x86_64" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
          nixpkgsConfig.allowUnfree = true;
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
