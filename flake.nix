{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    codex.url = "github:openai/codex?ref=rust-v0.142.0";
    googleworkspace-cli.url = "github:googleworkspace/cli/v0.22.5";
    notion-cli = {
      url = "github:lox/notion-cli/v0.6.0";
      flake = false;
    };
    emacs-sops = {
      url = "github:djgoku/sops";
      flake = false;
    };
    trueflow.url = "github:trueflow-dev/trueflow";
    voxtype.url = "github:peteonrails/voxtype/v1.0.0-rc1";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      codex,
      googleworkspace-cli,
      notion-cli,
      trueflow,
      voxtype,
      emacs-sops,
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
          version = "0.22.5";
          src = googleworkspace-cli;
          cargoLock.lockFile = "${googleworkspace-cli}/Cargo.lock";

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
          pkgs = import nixpkgs { inherit system; };
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
          packages = trueflow.packages.${system};
        in
        if packages ? native then packages.native else packages.default;

      mkPiPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.callPackage ./pkgs/omp { };

      mkOraclePkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.callPackage ./pkgs/oracle { };

      # Manually pinned claude-code (nixpkgs lags behind upstream releases).
      mkClaudeCodePkg =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/claude-code { };

      mkCodexPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          cargoToml = builtins.fromTOML (builtins.readFile "${codex}/codex-rs/Cargo.toml");
          version = cargoToml.workspace.package.version;
          darwinWebrtc =
            if system == "aarch64-darwin" then
              "${
                pkgs.fetchzip {
                  url = "https://github.com/livekit/rust-sdks/releases/download/webrtc-24f6822-2/webrtc-mac-arm64-release.zip";
                  hash = "sha256-EcwfNpYMoD8zf1ihsoYZJX0k/BewK3QHx7LjVADNbf0=";
                  stripRoot = false;
                }
              }/mac-arm64-release"
            else if system == "x86_64-darwin" then
              "${
                pkgs.fetchzip {
                  url = "https://github.com/livekit/rust-sdks/releases/download/webrtc-24f6822-2/webrtc-mac-x64-release.zip";
                  hash = "sha256-6ARl0EDCwX296hcLvDsEPOhOQ4qAhXGLfHF+Bn8fFII=";
                  stripRoot = false;
                }
              }/mac-x64-release"
            else
              null;
        in
        pkgs.callPackage ./pkgs/codex {
          inherit version darwinWebrtc;
          cargoHash = "sha256-fvEFNE12J6zaLZrN6oQB8X+jXoKPSCWrL17Sl28+7/c=";
          codexSrc = codex;
          nixpkgsPath = pkgs.path;
        };

      mkCodexDesktopPkg =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/codex-desktop { };

      mkFlowPkg =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
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
          lib,
          pkgs,
          ...
        }:
        {
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
          ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ voxtypePkg ]
          ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ codexDesktopPkg ];
          programs.voxtype = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
            enable = true;
            package = voxtypePkg;
            model.name = "base.en";
            service.enable = true;
            settings.hotkey.enabled = true;
          };
        };

      perSystem = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
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
            "tests/flow-search-smoke.sh"
            "tests/hive-smoke.sh"
          ];

          nixFiles = [
            "flake.nix"
            "home/common.nix"
            "home/direnv.nix"
            "home/emacs.nix"
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

          hiveOrchestratorTests =
            pkgs.runCommand "hive-orchestrator-tests"
              {
                nativeBuildInputs = [ pkgs.nodejs ];
              }
              ''
                cd ${./.}
                node --test \
                  home/.pi/agent/extensions/hive-orchestrator/core.test.ts \
                  home/.pi/agent/extensions/hive-orchestrator/orchestrator.test.ts
                touch $out
              '';

          hiveSmokeTests =
            pkgs.runCommand "hive-smoke-tests"
              {
                nativeBuildInputs = [ pkgs.bash ];
              }
              ''
                cd ${./.}
                bash tests/hive-smoke.sh
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
            default = pkgs.mkShell {
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
            home-manager = home-manager.packages.${system}.home-manager;
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
            flow = flowPkg;
            flow-smoke-tests = flowSmokeTests;
            hive-orchestrator-tests = hiveOrchestratorTests;
            hive-smoke-tests = hiveSmokeTests;
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
              program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
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
          pkgs = import nixpkgs {
            inherit system;
            config = nixpkgsConfig;
          };
        in
        home-manager.lib.homeManagerConfiguration {
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
