{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
    # Pinned to a release: this package handles decrypted secrets in every
    # Emacs session, so `nix flake update` must not move it unreviewed.
    emacs-sops = {
      url = "github:djgoku/sops/v0.2.1";
      flake = false;
    };
    trueflow = {
      url = "github:trueflow-dev/trueflow";
      inputs.flake-utils.follows = "flake-utils";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
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
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-pre-gcc16,
      flake-utils,
      rust-overlay,
      notion-cli,
      trueflow,
      voxtype,
      emacs-sops,
      home-manager,
      ...
    }:
    let
      # Packages that fail on current nixpkgs-unstable come from the pre-GCC 16
      # revision until their fixes land. Drop each use once it builds on
      # unstable, then drop this input:
      # - semgrep: the pyjwt fix (NixOS/nixpkgs#569851) landed, but its tests
      #   now fail importing mcp.server.fastmcp, removed in mcp 2.x
      #   (NixOS/nixpkgs#575004)
      # - prowler: depends on kingfisher 1.113.0, whose version check fails;
      #   fixed by NixOS/nixpkgs#569147, but Hydra has no aarch64-linux build
      #   on unstable yet
      # - cutter: uic in Qt 6.12 rejects its .ui files, NixOS/nixpkgs#576576
      pkgsPreGcc16For = system: import nixpkgs-pre-gcc16 { inherit system; };

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      # One package set per system and config. Nix does not memoize
      # `import nixpkgs { … }`, so an import in each builder below evaluated
      # nixpkgs a dozen times per system.
      pkgsBySystem = nixpkgs.lib.genAttrs systems (system: import nixpkgs { inherit system; });
      unfreePkgsBySystem = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }
      );
      rustPkgsBySystem = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        }
      );

      # Local crates build with the newest stable Rust in the locked rust-overlay
      # rather than whichever rustc the Nixpkgs revision happens to ship.
      rustPlatformFor =
        system:
        let
          pkgs = rustPkgsBySystem.${system};
          toolchain = pkgs.rust-bin.stable.latest.minimal;
        in
        pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };

      mkNotionCliPkg =
        system:
        let
          pkgs = pkgsBySystem.${system};
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
          pkgs = pkgsBySystem.${system};
        in
        pkgs.callPackage ./pkgs/omp { };

      mkOraclePkg =
        system:
        let
          pkgs = pkgsBySystem.${system};
        in
        # Node 24 in nixpkgs still links brotli without the CVE-2026-111497
        # fix; other majors carry it. Return to the default nodejs once
        # NixOS/nixpkgs#576792 lands. oracle needs node >=24, so not 22.
        pkgs.callPackage ./pkgs/oracle {
          buildNpmPackage = pkgs.buildNpmPackage.override { nodejs = pkgs.nodejs_26; };
        };

      # Manually pinned claude-code (nixpkgs lags behind upstream releases).
      mkClaudeCodePkg =
        system:
        let
          pkgs = unfreePkgsBySystem.${system};
        in
        pkgs.callPackage ./pkgs/claude-code { };

      mkCodexDesktopPkg =
        system:
        let
          pkgs = unfreePkgsBySystem.${system};
        in
        pkgs.callPackage ./pkgs/codex-desktop { };

      mkWisprFlowPkg =
        system:
        let
          pkgs = unfreePkgsBySystem.${system};
        in
        pkgs.callPackage ./pkgs/wispr-flow { };

      # Darwin apps whose pins in pins/ override nixpkgs; packaged so
      # `flow pin bump` can build them.
      mkPinnedAppPkg =
        name: system:
        let
          pkgs = unfreePkgsBySystem.${system};
        in
        pkgs.callPackage (./pkgs + "/${name}") { };

      mkFlowPkg =
        system:
        let
          pkgs = pkgsBySystem.${system};
        in
        pkgs.callPackage ./pkgs/flow {
          rustPlatform = rustPlatformFor system;
          zoekt = pkgs.callPackage ./pkgs/zoekt { };
        };

      mkOmpPhonePkg =
        system:
        let
          pkgs = pkgsBySystem.${system};
        in
        pkgs.callPackage ./projects/omp-phone { rustPlatform = rustPlatformFor system; };

      mkVoxtypePkg =
        system:
        let
          pkgs = pkgsBySystem.${system};
          upstream = voxtype.packages.${system};
          # Upstream's lock keeps webpki-roots and rustls-webpki releases that
          # trust the compromised eMudhra intermediates (RUSTSEC-2026-0381 to
          # 0383), plus rustls, quinn-proto and openssl releases with open
          # advisories. pkgs/voxtype/Cargo.lock is upstream's lock after
          #   cargo update -p rustls-webpki -p webpki-roots@<old> \
          #     -p webpki-root-certs -p rustls -p quinn-proto -p bytes \
          #     -p crossbeam-epoch -p openssl -p openssl-sys
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
            # Linux hosts with a BMC log as root instead (nixos/hosts/jmws-thermal.nix).
            # Apple Silicon dies run near 100 °C under sustained load, so
            # alert only past that.
            launchd.agents.flow-thermal = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
              enable = true;
              config = {
                ProgramArguments = [
                  "${flowPkg}/bin/flow"
                  "--automated"
                  "thermal"
                  "sample"
                  "--notify"
                  "--alert-at"
                  "105"
                ];
                StartInterval = 60;
                RunAtLoad = true;
                ProcessType = "Background";
                StandardOutPath = "/dev/null";
                StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/flow-thermal.err.log";
              };
            };
          };
        };

      perSystem = flake-utils.lib.eachSystem systems (
        system:
        let
          pkgs = pkgsBySystem.${system};
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
            "bin/cpu-throttle.sh"
            "bin/emacs-handcrafted"
            "bin/emacs-handcrafted-client"
            "bin/emacs-handcrafted-daemon"
            "bin/fan-mode.sh"
            "bin/git-clean-stale.sh"
            "bin/hm-switch.sh"
            "bin/linear"
            "bin/link-private-data.sh"
            "bin/lint-secrets.sh"
            "bin/omp-fan-out.sh"
            "bin/remove-nix-cache.sh"
            "bin/setup-git-hooks.sh"
            "bin/setup-homelab-ca.sh"
            "bin/vrm-check.sh"
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
                nativeBuildInputs = [ pkgs.nodejs_26 ];
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

          ompPhoneExtensionTests =
            pkgs.runCommand "omp-phone-extension-tests"
              {
                nativeBuildInputs = [ pkgs.nodejs_26 ];
              }
              ''
                cd ${
                  checkSource [
                    "projects/omp-phone/package.json"
                    "projects/omp-phone/extension/index.ts"
                    "projects/omp-phone/extension/index.test.ts"
                  ]
                }
                node --test projects/omp-phone/extension/index.test.ts
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
                  pkgs.shellcheck
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                # The Linux sandbox has no /usr/bin/env; the hook executes
                # bin/lint-secrets.sh directly, so its shebang must resolve.
                cp -r --no-preserve=mode ${
                  checkSource [
                    ".githooks/pre-push"
                    "bin/lint-secrets.sh"
                    "tests/pre-push-secrets.sh"
                  ]
                } src
                chmod +x src/bin/lint-secrets.sh
                patchShebangs src
                cd src
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
              # The pre-push secret scan only protects a checkout whose
              # core.hooksPath points at .githooks, and a fresh clone's does
              # not. Entering the dev shell at the repo root (direnv does
              # this) turns it on.
              shellHook = ''
                if [ -f .githooks/pre-push ] && [ -f bin/setup-git-hooks.sh ] &&
                  [ "$(git config --get core.hooksPath 2>/dev/null)" != .githooks ]; then
                  git config core.hooksPath .githooks 2>/dev/null || true
                fi
              '';
            };

          };

          packages = {
            claude-code = claudeCodePkg;
            flow = flowPkg;
            gogcli = pkgs.gogcli;
            googleworkspace-cli = pkgs.gws;
            home-manager = home-manager.packages.${system}.home-manager;
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
            spotify = mkPinnedAppPkg "spotify" system;
            whatsapp = mkPinnedAppPkg "whatsapp" system;
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
            omp-phone-extension-tests = ompPhoneExtensionTests;
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
              program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
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
          pkgs = import nixpkgs {
            inherit system;
            config = nixpkgsConfig;
          };
        in
        home-manager.lib.homeManagerConfiguration {
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
          specialArgs = {
            flowPkg = mkFlowPkg system;
          };
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
        "work-macos-aarch64" = mkMacosHome {
          system = "aarch64-darwin";
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
