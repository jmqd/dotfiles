{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-darwin-x86.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # Last nixpkgs-unstable revision before the GCC 16 / pyjwt 2.14 breakage;
    # see pkgsPreGcc16For below.
    nixpkgs-pre-gcc16.url = "github:NixOS/nixpkgs/00455b0a3690d3f5dc61e9aef4277dc86235b73f";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
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
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    trueflow-darwin-x86 = {
      # Same source as `trueflow`; only the Nixpkgs edge differs for Intel Darwin.
      url = "github:trueflow-dev/trueflow/473fec184e1901db76081c6002a115c07cab2a94";
      inputs.flake-utils.follows = "flake-utils";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs-darwin-x86";
    };
    voxtype = {
      url = "github:peteonrails/voxtype/v1.1.1";
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
      nixpkgs-pre-gcc16,
      flake-utils,
      rust-overlay,
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

      # Packages that fail on current nixpkgs-unstable come from the pre-GCC 16
      # revision until their fixes land. Drop each use once it builds on
      # unstable, then drop this input:
      # - semgrep: requires pyjwt 2.13, NixOS/nixpkgs#569851
      # - prowler: depends on kingfisher 1.113.0, whose version check fails;
      #   fixed by NixOS/nixpkgs#569147, but Hydra has no aarch64-linux build
      #   on unstable yet
      # - cutter: uic in Qt 6.12 rejects its .ui files, NixOS/nixpkgs#576576
      # Intel Darwin stays on its own 26.05 release branch.
      pkgsPreGcc16For =
        system:
        import (if system == "x86_64-darwin" then nixpkgs-darwin-x86 else nixpkgs-pre-gcc16) {
          inherit system;
        };

      # Local crates build with the newest stable Rust in the locked rust-overlay
      # rather than whichever rustc the Nixpkgs revision happens to ship.
      rustPlatformFor =
        system:
        let
          pkgs = import (nixpkgsFor system) {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          toolchain = pkgs.rust-bin.stable.latest.minimal;
        in
        pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
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

      mkCodexDesktopPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/codex-desktop { };

      mkWisprFlowPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) {
            inherit system;
            config.allowUnfree = true;
          };
        in
        pkgs.callPackage ./pkgs/wispr-flow { };

      mkFlowPkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.callPackage ./pkgs/flow {
          rustPlatform = rustPlatformFor system;
          zoekt = pkgs.callPackage ./pkgs/zoekt { };
        };

      mkOmpPhonePkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
        in
        pkgs.callPackage ./projects/omp-phone { rustPlatform = rustPlatformFor system; };

      mkVoxtypePkg =
        system:
        let
          pkgs = import (nixpkgsFor system) { inherit system; };
          upstream = voxtype.packages.${system};
          # Upstream's lock keeps webpki-roots and rustls-webpki releases that
          # trust the compromised eMudhra intermediates (RUSTSEC-2026-0381 to
          # 0383), plus rustls and quinn-proto releases with open advisories.
          # pkgs/voxtype/Cargo.lock is upstream's lock after
          #   cargo update -p rustls-webpki -p webpki-roots@<old> \
          #     -p webpki-root-certs -p rustls -p quinn-proto -p bytes -p crossbeam-epoch
          # Regenerate it on each voxtype bump; drop it once upstream catches up.
          lockFile = ./pkgs/voxtype/Cargo.lock;
          unwrapped = upstream.voxtype-vulkan-unwrapped.overrideAttrs (old: {
            cargoDeps = pkgs.rustPlatform.importCargoLock {
              inherit lockFile;
              outputHashes = {
                "openvino-finder-0.11.0" = "sha256-nQWeHNdLlRk+owh3B6VpArAG2dr66HeBI2RHfDhyvvU=";
                "openvino-genai-0.11.0" = "sha256-nQWeHNdLlRk+owh3B6VpArAG2dr66HeBI2RHfDhyvvU=";
                "openvino-genai-sys-0.11.0" = "sha256-nQWeHNdLlRk+owh3B6VpArAG2dr66HeBI2RHfDhyvvU=";
                "openvino-sys-0.11.0" = "sha256-nQWeHNdLlRk+owh3B6VpArAG2dr66HeBI2RHfDhyvvU=";
              };
            };
            postPatch = (old.postPatch or "") + ''
              cp ${lockFile} Cargo.lock
            '';
          });
        in
        # Vulkan gives the NVIDIA Linux desktop GPU acceleration without
        # introducing the CUDA/ONNX closure into every Home Manager switch.
        upstream.vulkan.overrideAttrs { paths = [ unwrapped ]; }
        // {
          inherit (unwrapped) version;
        };

      mkHomePackagesModule =
        system:
        let
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          oraclePkg = mkOraclePkg system;
          claudeCodePkg = mkClaudeCodePkg system;
          codexDesktopPkg = mkCodexDesktopPkg system;
          flowPkg = mkFlowPkg system;
          ompPhonePkg = mkOmpPhonePkg system;
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
              flowPkg
              pkgs.gws
              notionCliPkg
              oraclePkg
              piPkg
              trueflowPkg
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ codexDesktopPkg ];
            services.omp-phone.package = ompPhonePkg;
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
          notionCliPkg = mkNotionCliPkg system;
          trueflowPkg = mkTrueflowPkg system;
          piPkg = mkPiPkg system;
          oraclePkg = mkOraclePkg system;
          claudeCodePkg = mkClaudeCodePkg system;
          codexDesktopPkg = mkCodexDesktopPkg system;
          wisprFlowPkg = mkWisprFlowPkg system;
          flowPkg = mkFlowPkg system;
          voxtypePkg = mkVoxtypePkg system;

          shellScriptFiles = [
            ".githooks/pre-push"
            "bin/audit-deps.sh"
            "bin/bootstrap-macos.sh"
            "bin/bootstrap-rust.sh"
            "bin/clean-stale.sh"
            "bin/git-clean-stale.sh"
            "bin/hm-switch.sh"
            "bin/link-private-data.sh"
            "bin/lint-secrets.sh"
            "bin/setup-git-hooks.sh"
            "bin/setup-nix-cache.sh"
            "tests/bootstrap-rust-mapfile.sh"
            "tests/clean-stale.sh"
            "tests/flow-search-smoke.sh"
            "tests/git-clean-stale.sh"
            "tests/hm-switch-failure.sh"
            "tests/pre-push-secrets.sh"
          ];

          checkSource =
            files:
            pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions (map (file: ./. + "/${file}") files);
            };
          shellCheckSource = checkSource shellScriptFiles;

          nixFiles = map (path: pkgs.lib.removePrefix "${toString ./.}/" (toString path)) (
            builtins.filter (path: pkgs.lib.hasSuffix ".nix" (toString path)) (
              pkgs.lib.filesystem.listFilesRecursive ./.
            )
          );

          nixfmtCheck =
            pkgs.runCommand "nixfmt-check"
              {
                nativeBuildInputs = [ pkgs.nixfmt ];
              }
              ''
                cd ${checkSource nixFiles}
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
                cd ${shellCheckSource}
                shellcheck ${pkgs.lib.escapeShellArgs shellScriptFiles}
                touch $out
              '';

          shfmtCheck =
            pkgs.runCommand "shfmt-bin-scripts"
              {
                nativeBuildInputs = [ pkgs.shfmt ];
              }
              ''
                cd ${shellCheckSource}
                shfmt -d ${pkgs.lib.escapeShellArgs shellScriptFiles}
                touch $out
              '';

          reviewOrchestratorTests =
            pkgs.runCommand "review-orchestrator-tests"
              {
                nativeBuildInputs = [ pkgs.nodejs ];
              }
              ''
                cd ${
                  checkSource [
                    "home/.pi/agent/extensions/review-orchestrator/core.ts"
                    "home/.pi/agent/extensions/review-orchestrator/core.test.ts"
                  ]
                }
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
                cd ${
                  checkSource [
                    "bin/bootstrap-rust.sh"
                    "tests/bootstrap-rust-mapfile.sh"
                  ]
                }
                bash tests/bootstrap-rust-mapfile.sh
                touch $out
              '';

          cleanStaleTests =
            pkgs.runCommand "clean-stale-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.git
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.lsof
                  pkgs.ps
                ];
              }
              ''
                cd ${
                  checkSource [
                    "bin/clean-stale.sh"
                    "tests/clean-stale.sh"
                  ]
                }
                bash tests/clean-stale.sh
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
                cd ${checkSource [ "tests/flow-search-smoke.sh" ]}
                bash tests/flow-search-smoke.sh
                touch $out
              '';

          gitCleanStaleTests =
            pkgs.runCommand "git-clean-stale-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.git
                  pkgs.gnugrep
                ];
              }
              ''
                cd ${
                  checkSource [
                    "bin/git-clean-stale.sh"
                    "tests/git-clean-stale.sh"
                  ]
                }
                bash tests/git-clean-stale.sh
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
                cd ${
                  checkSource [
                    "bin/hm-switch.sh"
                    "tests/hm-switch-failure.sh"
                  ]
                }
                bash tests/hm-switch-failure.sh
                touch $out
              '';

          prePushSecretsTests =
            pkgs.runCommand "pre-push-secrets-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.git
                  pkgs.gitleaks
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                cd ${
                  checkSource [
                    ".githooks/pre-push"
                    "bin/lint-secrets.sh"
                    "tests/pre-push-secrets.sh"
                  ]
                }
                bash tests/pre-push-secrets.sh
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
                  gogcli
                  gws
                  just
                  jq
                  python3
                  shellcheck
                  shfmt
                ])
                ++ [
                  piPkg
                  trueflowPkg
                ];
            };

          };

          packages = {
            claude-code = claudeCodePkg;
            flow = flowPkg;
            gogcli = pkgs.gogcli;
            googleworkspace-cli = pkgs.gws;
            home-manager = (homeManagerFor system).packages.${system}.home-manager;
            notion-cli = notionCliPkg;
            omp = piPkg;
            omp-phone = mkOmpPhonePkg system;
            oracle = oraclePkg;
            pi = piPkg;
            secrets-lint = secretsLint;
            spotify-export = pkgs.callPackage ./projects/spotify-export { };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = voxtypePkg;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = codexDesktopPkg;
            wispr-flow = wisprFlowPkg;
          };

          checks = {
            bootstrap-rust-tests = bootstrapRustTests;
            claude-code = claudeCodePkg;
            clean-stale-tests = cleanStaleTests;
            flow = flowPkg;
            flow-smoke-tests = flowSmokeTests;
            googleworkspace-cli = pkgs.gws;
            git-clean-stale-tests = gitCleanStaleTests;
            hm-switch-tests = hmSwitchTests;
            nixfmt = nixfmtCheck;
            notion-cli = notionCliPkg;
            omp = piPkg;
            oracle = oraclePkg;
            pre-push-secrets-tests = prePushSecretsTests;
            review-orchestrator-tests = reviewOrchestratorTests;
            secrets-lint = secretsLintCheck;
            shellcheck-bin-scripts = shellcheckCheck;
            shfmt-bin-scripts = shfmtCheck;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = voxtypePkg;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = codexDesktopPkg;
            wispr-flow = wisprFlowPkg;
          };

          apps = {
            claude-code = {
              type = "app";
              program = "${claudeCodePkg}/bin/claude";
              meta.description = "Run Claude Code";
            };
            flow = {
              type = "app";
              program = "${flowPkg}/bin/flow";
              meta.description = "Run Flow";
            };
            home-manager = {
              type = "app";
              program = "${(homeManagerFor system).packages.${system}.home-manager}/bin/home-manager";
              meta.description = "Run Home Manager";
            };
            omp = {
              type = "app";
              program = "${piPkg}/bin/omp";
              meta.description = "Run OMP";
            };
            oracle = {
              type = "app";
              program = "${oraclePkg}/bin/oracle";
              meta.description = "Run Oracle";
            };
            oracle-mcp = {
              type = "app";
              program = "${oraclePkg}/bin/oracle-mcp";
              meta.description = "Run the Oracle MCP server";
            };
            pi = {
              type = "app";
              program = "${piPkg}/bin/pi";
              meta.description = "Run the Pi compatibility alias";
            };
            secrets-lint = {
              type = "app";
              program = "${secretsLint}/bin/secrets-lint";
              meta.description = "Scan the repository for secrets";
            };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = {
              type = "app";
              program = "${voxtypePkg}/bin/voxtype";
              meta.description = "Run Voxtype";
            };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = {
              type = "app";
              program = "${codexDesktopPkg}/Applications/Codex.app/Contents/MacOS/ChatGPT";
              meta.description = "Run Codex desktop";
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
            pkgsPreGcc16 = pkgsPreGcc16For system;
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
                "whatsapp-for-mac"
                "wispr-flow"
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
                pkgsPreGcc16 = pkgsPreGcc16For system;
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
