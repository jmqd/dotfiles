{
  description = "dotfiles tooling";

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-darwin-x86.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";
    codex = {
      url = "git+https://github.com/openai/codex?ref=refs/tags/rust-v0.144.6";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    googleworkspace-cli = {
      url = "github:googleworkspace/cli/v0.22.5";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    notion-cli = {
      url = "github:lox/notion-cli/v0.6.0";
      flake = false;
    };
    emacs-sops = {
      url = "github:djgoku/sops";
      flake = false;
    };
    trueflow = {
      url = "github:trueflow-dev/trueflow";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    trueflow-darwin-x86 = {
      # Same source as `trueflow`; only the Nixpkgs edge differs for Intel Darwin.
      url = "github:trueflow-dev/trueflow/3af46222bd98a4bb6d881cb5f6687530e9ab1fdd";
      inputs.flake-utils.follows = "flake-utils";
      inputs.rust-overlay.follows = "trueflow/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs-darwin-x86";
    };
    voxtype = {
      url = "github:peteonrails/voxtype/v1.0.0-rc1";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-darwin-x86 = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-darwin-x86";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin-x86,
      flake-utils,
      codex,
      googleworkspace-cli,
      notion-cli,
      trueflow,
      trueflow-darwin-x86,
      voxtype,
      emacs-sops,
      home-manager,
      home-manager-darwin-x86,
      ...
    }:
    let
      nixpkgsFor = system: if system == "x86_64-darwin" then nixpkgs-darwin-x86 else nixpkgs;
      trueflowFor = system: if system == "x86_64-darwin" then trueflow-darwin-x86 else trueflow;
      homeManagerFor =
        system: if system == "x86_64-darwin" then home-manager-darwin-x86 else home-manager;

      mkGoogleworkspaceCliPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.rustPlatform.buildRustPackage {
          pname = "gws";
          version = "0.22.5";
          src = googleworkspace-cli;
          cargoLock.lockFile = "${googleworkspace-cli}/Cargo.lock";
          # Upstream's encrypted-credentials test leaves this process-global
          # variable set to a temporary directory, which can make the later
          # config_dir test fail nondeterministically.
          postPatch = ''
            substituteInPlace crates/google-workspace-cli/src/auth.rs \
              --replace-fail \
                'std::env::set_var("GOOGLE_WORKSPACE_CLI_CONFIG_DIR", dir.path());' \
                'let _config_guard = EnvVarGuard::set("GOOGLE_WORKSPACE_CLI_CONFIG_DIR", dir.path());'
          '';

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          preCheck = ''
            export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$TMPDIR/gws"
            mkdir -p "$GOOGLE_WORKSPACE_CLI_CONFIG_DIR"
          '';

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
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.buildGoModule {
          pname = "notion-cli";
          version = "0.6.0";
          src = notion-cli;
          vendorHash = "sha256-SXs/voGAlA66aGMUC6GzttSejo9kSSOVdujp5Nl9GZM=";

          ldflags = [
            "-X main.version=v0.6.0"
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
          packages = (trueflowFor system).packages.${system};
        in
        if packages ? native then packages.native else packages.default;

      mkPiPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.callPackage ./pkgs/omp { };

      mkOraclePkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.callPackage ./pkgs/oracle { };

      # Manually pinned claude-code (nixpkgs lags behind upstream releases).
      mkClaudeCodePkg =
        system:
        let
          pkgs = import (nixpkgsFor system) {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/claude-code { };

      mkCodexPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
          cargoToml = builtins.fromTOML (builtins.readFile "${codex}/codex-rs/Cargo.toml");
          version = cargoToml.workspace.package.version;
        in
        pkgs.callPackage ./pkgs/codex {
          inherit version;
          cargoHash = "sha256-S4dsZXfmKvJItL2XYKyxfhqdCMATEG6oPjrtVRwkuYc=";
          codexSrc = codex;
          nixpkgsPath = pkgs.path;
        };

      mkCodexDesktopPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/codex-desktop { };

      mkFlowPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.callPackage ./pkgs/flow { };

      mkVoxtypePkg =
        system:
        # Vulkan gives the NVIDIA Linux desktop GPU acceleration without
        # introducing the CUDA/ONNX closure into every Home Manager switch.
        voxtype.packages.${system}.vulkan;

      mkHomePackagesModule =
        system:
        let
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          oraclePkg = mkOraclePkg system;
          claudeCodePkg = mkClaudeCodePkg system;
          codexPkg = mkCodexPkg system;
          codexDesktopPkg = mkCodexDesktopPkg system;
          flowPkg = mkFlowPkg system;
          voxtypePkg = mkVoxtypePkg system;
        in
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          options.jmq.packageSets.customCli.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Install locally packaged CLI/AI tools from this flake. Disable on
              slower machines to keep Home Manager switches on mostly cached
              nixpkgs packages.
            '';
          };

          config = lib.mkIf config.jmq.packageSets.customCli.enable {
            home.packages = [
              claudeCodePkg
              codexPkg
              flowPkg
              googleworkspaceCliPkg
              notionCliPkg
              oraclePkg
              piPkg
              trueflowPkg
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ codexDesktopPkg ];
            programs.voxtype = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
              enable = true;
              package = voxtypePkg;
              model.name = "base.en";
              service.enable = true;
              settings.hotkey.enabled = true;
            };
          };
        };

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
          googleworkspaceCliPkg = mkGoogleworkspaceCliPkg system;
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          oraclePkg = mkOraclePkg system;
          claudeCodePkg = mkClaudeCodePkg system;
          codexPkg = mkCodexPkg system;
          codexDesktopPkg = mkCodexDesktopPkg system;
          flowPkg = mkFlowPkg system;
          voxtypePkg = mkVoxtypePkg system;

          shellScriptFiles = [
            "bin/audit-deps.sh"
            "bin/bootstrap-macos.sh"
            "bin/bootstrap-rust.sh"
            "bin/hm-switch.sh"
            "bin/link-private-data.sh"
            "bin/lint-secrets.sh"
            "bin/setup-git-hooks.sh"
            "tests/bootstrap-rust-mapfile.sh"
            "tests/flow-search-smoke.sh"
            "tests/hm-switch-failure.sh"
          ];

          nixFiles = [
            "flake.nix"
            "home/common.nix"
            "home/direnv.nix"
            "home/emacs.nix"
            "home/env.nix"
            "home/files.nix"
            "home/flow-search.nix"
            "home/git.nix"
            "home/gpg.nix"
            "home/linux-desktop.nix"
            "home/linux.nix"
            "home/ssh.nix"
            "home/tmux.nix"
            "home/trueflow.nix"
            "home/wezterm.nix"
            "home/yubikey.nix"
            "home/zsh.nix"
            "nixos/configuration.nix"
            "nixos/hardware-configuration.nix"
            "nixos/hosts/jmws.nix"
            "pkgs/berkley-mono/default.nix"
            "pkgs/claude-code/default.nix"
            "pkgs/codex/default.nix"
            "pkgs/codex-desktop/default.nix"
            "pkgs/flow/default.nix"
            "pkgs/oracle/default.nix"
            "pkgs/pi/default.nix"
          ];

          nixfmtCheck =
            pkgs.runCommand "nixfmt-check"
              {
                nativeBuildInputs = [ pkgs.nixfmt ];
              }
              ''
                cd ${./.}
                nixfmt --check ${pkgs.lib.escapeShellArgs nixFiles}
                touch $out
              '';

          repoFormatter = pkgs.writeShellApplication {
            name = "dotfiles-fmt";
            runtimeInputs = [ pkgs.nixfmt ];
            text = ''
              if [ "$#" -eq 0 ]; then
                set -- ${pkgs.lib.escapeShellArgs nixFiles}
              fi

              exec nixfmt "$@"
            '';
          };

          shellcheckCheck =
            pkgs.runCommand "shellcheck-bin-scripts"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
              }
              ''
                cd ${./.}
                shellcheck ${pkgs.lib.escapeShellArgs shellScriptFiles}
                touch $out
              '';

          shfmtCheck =
            pkgs.runCommand "shfmt-bin-scripts"
              {
                nativeBuildInputs = [ pkgs.shfmt ];
              }
              ''
                cd ${./.}
                shfmt -d ${pkgs.lib.escapeShellArgs shellScriptFiles}
                touch $out
              '';

          reviewOrchestratorTests =
            pkgs.runCommand "review-orchestrator-tests"
              {
                nativeBuildInputs = [ pkgs.nodejs ];
              }
              ''
                cd ${./.}
                node --test home/.pi/agent/extensions/review-orchestrator/core.test.ts
                touch $out
              '';

          bootstrapRustTests =
            pkgs.runCommand "bootstrap-rust-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                ];
              }
              ''
                cd ${./.}
                bash tests/bootstrap-rust-mapfile.sh
                touch $out
              '';

          flowSmokeTests =
            pkgs.runCommand "flow-smoke-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.git
                  pkgs.jq
                  flowPkg
                ];
              }
              ''
                cd ${./.}
                bash tests/flow-search-smoke.sh
                touch $out
              '';

          hmSwitchTests =
            pkgs.runCommand "hm-switch-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                ];
              }
              ''
                cd ${./.}
                bash tests/hm-switch-failure.sh
                touch $out
              '';

          secretsLint = pkgs.writeShellApplication {
            name = "secrets-lint";
            runtimeInputs = [ pkgs.gitleaks ];
            text = ''
              set -euo pipefail
              exec gitleaks dir --config .gitleaks.toml --redact --exit-code 1 --no-banner .
            '';
          };

          secretsLintCheck =
            pkgs.runCommand "secrets-lint-check"
              {
                nativeBuildInputs = [ secretsLint ];
              }
              ''
                cd ${./.}
                secrets-lint
                touch $out
              '';
        in
        {
          formatter = repoFormatter;

          devShells = {
            default = pkgs.mkShellNoCC {
              packages =
                (with pkgs; [
                  awscli2
                  curl
                  git
                  gitleaks
                  just
                  jq
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

          };

          packages = {
            claude-code = claudeCodePkg;
            codex = codexPkg;
            flow = flowPkg;
            googleworkspace-cli = googleworkspaceCliPkg;
            home-manager = (homeManagerFor system).packages.${system}.home-manager;
            notion-cli = notionCliPkg;
            omp = piPkg;
            oracle = oraclePkg;
            pi = piPkg;
            secrets-lint = secretsLint;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = voxtypePkg;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = codexDesktopPkg;
          };

          checks = {
            bootstrap-rust-tests = bootstrapRustTests;
            flow = flowPkg;
            flow-smoke-tests = flowSmokeTests;
            hm-switch-tests = hmSwitchTests;
            nixfmt = nixfmtCheck;
            review-orchestrator-tests = reviewOrchestratorTests;
            secrets-lint = secretsLintCheck;
            shellcheck-bin-scripts = shellcheckCheck;
            shfmt-bin-scripts = shfmtCheck;
          };

          apps = {
            claude-code = {
              type = "app";
              program = "${claudeCodePkg}/bin/claude";
            };
            codex = {
              type = "app";
              program = "${codexPkg}/bin/codex";
            };
            flow = {
              type = "app";
              program = "${flowPkg}/bin/flow";
            };
            home-manager = {
              type = "app";
              program = "${(homeManagerFor system).packages.${system}.home-manager}/bin/home-manager";
            };
            omp = {
              type = "app";
              program = "${piPkg}/bin/omp";
            };
            oracle = {
              type = "app";
              program = "${oraclePkg}/bin/oracle";
            };
            oracle-mcp = {
              type = "app";
              program = "${oraclePkg}/bin/oracle-mcp";
            };
            pi = {
              type = "app";
              program = "${piPkg}/bin/pi";
            };
            secrets-lint = {
              type = "app";
              program = "${secretsLint}/bin/secrets-lint";
            };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = {
              type = "app";
              program = "${voxtypePkg}/bin/voxtype";
            };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = {
              type = "app";
              program = "${codexDesktopPkg}/Applications/Codex.app/Contents/MacOS/Codex";
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
          pkgs = import (nixpkgsFor system) {
            inherit system;
            config = nixpkgsConfig;
          };
        in
        (homeManagerFor system).lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            inherit emacs-sops;
          };
          modules = [
            module
            (mkHomePackagesModule system)
            voxtype.homeManagerModules.default
          ]
          ++ extraModules;
        };

      mkMacosHome =
        {
          system,
          extraModules ? [ ],
        }:
        let
          bootstrapUser =
            let
              explicitUser = builtins.getEnv "HM_BOOTSTRAP_USER";
              envUser = builtins.getEnv "USER";
            in
            if explicitUser != "" then
              explicitUser
            else if envUser != "" then
              envUser
            else
              "jmq";
          bootstrapHome =
            let
              envHome = builtins.getEnv "HOME";
            in
            if envHome != "" then envHome else "/Users/${bootstrapUser}";
        in
        mkHome {
          inherit system;
          module = ./home/hosts/jmq-macos.nix;
          nixpkgsConfig = {
            allowUnfreePredicate =
              pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [
                "berkley-mono"
                "claude-code"
                "codex-desktop"
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
          ]
          ++ extraModules;
        };

      linuxNixpkgsConfig = {
        allowUnfree = true;
        permittedInsecurePackages = [ "googleearth-pro-7.3.7.1155" ];
      };

      liteHomeModule =
        { lib, ... }:
        {
          jmq.packageSets.customCli.enable = false;
          jmq.linux.desktop.enable = false;
          jmq.linux.heavyweightApps.enable = false;
          jmq.yubikey.otp.longPressOnly.enforceOnActivation = lib.mkForce false;
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
              home-manager.backupFileExtension = "hm-backup";
              home-manager.useGlobalPkgs = true;
              home-manager.extraSpecialArgs = {
                inherit emacs-sops;
              };
              home-manager.users.jmq =
                {
                  ...
                }:
                {
                  imports = [
                    homeModule
                    (mkHomePackagesModule system)
                    voxtype.homeManagerModules.default
                  ];
                };
            }
          ];
        };
    in
    perSystem
    // {
      homeConfigurations = {
        "macos-aarch64" = mkMacosHome { system = "aarch64-darwin"; };
        "macos-x86_64" = mkMacosHome { system = "x86_64-darwin"; };
        "work-macos-aarch64" = mkMacosHome {
          system = "aarch64-darwin";
          extraModules = [ ./home/hosts/work-macos.nix ];
        };
        "work-macos-x86_64" = mkMacosHome {
          system = "x86_64-darwin";
          extraModules = [ ./home/hosts/work-macos.nix ];
        };
        "linux-aarch64" = mkHome {
          system = "aarch64-linux";
          module = ./home/hosts/jmq-linux.nix;
          nixpkgsConfig = linuxNixpkgsConfig;
        };
        "linux-aarch64-lite" = mkHome {
          system = "aarch64-linux";
          module = ./home/hosts/jmq-linux.nix;
          extraModules = [ liteHomeModule ];
          nixpkgsConfig = linuxNixpkgsConfig;
        };
        "linux-x86_64" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
          nixpkgsConfig = linuxNixpkgsConfig;
        };
        "linux-x86_64-lite" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
          extraModules = [ liteHomeModule ];
          nixpkgsConfig = linuxNixpkgsConfig;
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
