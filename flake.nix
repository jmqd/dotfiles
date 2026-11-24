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
    # Commit on main after v0.6.0 that updates the dependencies behind most of
    # the release's Go advisories. Return to a tag at the next release.
    notion-cli = {
      url = "github:lox/notion-cli/f237f53ead3475716757caf726e6068d73bc4060";
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
      url = "github:peteonrails/voxtype/v1.3.0";
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
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      # Packages that fail on current nixpkgs-unstable come from the pre-GCC 16
      # revision until their fixes land. Drop each use once it builds on
      # unstable, then drop this input:
      # - prowler on aarch64-linux: fixed by NixOS/nixpkgs#569147, but Hydra
      #   has no aarch64-linux build on unstable yet
      # - cutter: uic in Qt 6.12 rejects its .ui files, NixOS/nixpkgs#576576
      pkgsPreGcc16BySystem = nixpkgs.lib.genAttrs systems (
        system: import nixpkgs-pre-gcc16 { inherit system; }
      );
      pkgsPreGcc16For = system: pkgsPreGcc16BySystem.${system};

      # One package set per system and config. Reuse nixpkgs.legacyPackages for
      # the plain set so flake.nix shares the same instance as home-manager and
      # voxtype instead of evaluating another copy of nixpkgs per system.
      pkgsBySystem = nixpkgs.lib.genAttrs systems (system: nixpkgs.legacyPackages.${system});
      unfreePkgsBySystem = nixpkgs.lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }
      );

      macosAllowUnfree = [
        "antigravity-cli"
        "berkley-mono"
        "claude-code"
        "codex-desktop"
        "gemini"
        "orbstack"
        "raycast"
        "spotify"
        "whatsapp-for-mac"
        "wispr-flow"
      ];
      macosPkgsBySystem = nixpkgs.lib.genAttrs [ "aarch64-darwin" ] (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) macosAllowUnfree;
        }
      );

      # Local crates build with the newest stable Rust in the locked rust-overlay
      # rather than whichever rustc the Nixpkgs revision happens to ship.
      # mkRustBin reuses the caller's package set; applying the overlay would
      # evaluate another copy of nixpkgs per system.
      mkRustPlatform =
        pkgs:
        let
          toolchain = (rust-overlay.lib.mkRustBin { } pkgs).stable.latest.minimal;
        in
        pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };

      rustPlatformBySystem = nixpkgs.lib.genAttrs systems (system: mkRustPlatform pkgsBySystem.${system});

      trueflowBySystem = nixpkgs.lib.genAttrs systems (
        system:
        let
          packages = trueflow.packages.${system};
        in
        if packages ? native then packages.native else packages.default
      );

      mkLocalPackages =
        {
          pkgs,
          unfreePkgs ? pkgs,
          rustPlatform ? mkRustPlatform pkgs,
        }:
        let
          system = pkgs.stdenv.hostPlatform.system;
          mkPinnedApp = name: unfreePkgs.callPackage (./pkgs + "/${name}") { };
        in
        {
          notion-cli = pkgs.buildGoModule rec {
            pname = "notion-cli";
            version = "0.6.0-unstable-2026-11-01";
            src = notion-cli;
            vendorHash = "sha256-nvdNSQ2wr3adSEon7EAYpDwOx2vyybq+t9qaZIDV2g4=";

            ldflags = [
              "-X main.version=v${version}"
            ];

            meta = with pkgs.lib; {
              description = "Notion CLI";
              homepage = "https://github.com/lox/notion-cli";
              license = licenses.mit;
              mainProgram = "notion-cli";
              platforms = platforms.unix;
            };
          };

          trueflow = trueflowBySystem.${system};

          omp = pkgs.callPackage ./pkgs/omp { };

          oracle = pkgs.callPackage ./pkgs/oracle { };

          # Manually pinned Antigravity CLI (nixpkgs lags behind upstream releases).
          antigravity-cli = unfreePkgs.callPackage ./pkgs/antigravity-cli { };

          # Manually pinned claude-code (nixpkgs lags behind upstream releases).
          claude-code = unfreePkgs.callPackage ./pkgs/claude-code { };

          # Manually pinned Gemini CLI (nixpkgs lags behind upstream releases).
          gemini-cli = pkgs.callPackage ./pkgs/gemini-cli { };

          codex-desktop = unfreePkgs.callPackage ./pkgs/codex-desktop { };

          wispr-flow = unfreePkgs.callPackage ./pkgs/wispr-flow { };

          # Darwin apps whose pins in pins/ override nixpkgs; packaged so
          # `flow pin bump` can build them. xcodes is MIT-licensed and uses the
          # free package set.
          gemini = mkPinnedApp "gemini";
          spotify = mkPinnedApp "spotify";
          whatsapp = mkPinnedApp "whatsapp";
          xcodes = pkgs.callPackage ./pkgs/xcodes { };

          flow = pkgs.callPackage ./pkgs/flow {
            inherit rustPlatform;
            zoekt = pkgs.callPackage ./pkgs/zoekt { };
          };

          omp-phone = pkgs.callPackage ./projects/omp-phone { inherit rustPlatform; };

          spotify-export = pkgs.callPackage ./projects/spotify-export { inherit rustPlatform; };

          voxtype =
            let
              upstream = voxtype.packages.${system};
              # Upstream's lock keeps releases with open advisories (most
              # recently quinn-udp, RUSTSEC-2026-0538). pkgs/voxtype/Cargo.lock
              # is upstream's lock after
              #   cargo update -p rustls-webpki -p webpki-roots@<old> -p rustls \
              #     -p quinn-proto -p quinn-udp -p bytes -p crossbeam-epoch
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
                # nixpkgs' cargoSetupHook sets LIBSQLITE3_SYS_USE_PKG_CONFIG=1,
                # which overrides rusqlite's `bundled` feature and links the
                # system sqlite that upstream's flake does not provide.
                buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.sqlite ];
                # Racy upstream tests. The meeting_title one asserts the daemon
                # has not yet rewritten the transcript after a live retitle, and
                # a fast builder loses that race. The oauth ones re-bind local
                # ports that parallel tests' forked children can still hold, so
                # they fail with PortsBusy now and then (see free_port upstream).
                checkFlags = (old.checkFlags or [ ]) ++ [
                  "--skip=a_running_meeting_is_retitled_through_the_daemon"
                  "--skip=meeting::actions::oauth::tests::"
                ];
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
        };

      localPkgsBySystem = nixpkgs.lib.genAttrs systems (
        system:
        mkLocalPackages {
          pkgs = pkgsBySystem.${system};
          unfreePkgs = unfreePkgsBySystem.${system};
          rustPlatform = rustPlatformBySystem.${system};
        }
      );

      macosLocalPkgsBySystem = nixpkgs.lib.genAttrs [ "aarch64-darwin" ] (
        system: mkLocalPackages { pkgs = macosPkgsBySystem.${system}; }
      );

      unfreeLocalPkgsBySystem = nixpkgs.lib.genAttrs systems (
        system: mkLocalPackages { pkgs = unfreePkgsBySystem.${system}; }
      );

      mkHomePackagesModule =
        {
          localPkgs ? null,
        }:
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          local = if localPkgs != null then localPkgs else mkLocalPackages { inherit pkgs; };
        in
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

          config = lib.mkMerge [
            # A prebuilt download, so lite homes that skip customCli keep it.
            { home.packages = [ local.antigravity-cli ]; }
            (lib.mkIf config.jmq.packageSets.customCli.enable {
              home.packages = [
                local.claude-code
                local.flow
                local.gemini-cli
                pkgs.gws
                local.notion-cli
                local.oracle
                local.omp
                local.trueflow
              ]
              ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ local.codex-desktop ];
              services.omp-phone.package = local.omp-phone;
              programs.voxtype = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
                enable = true;
                package = local.voxtype;
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
                    "${local.flow}/bin/flow"
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
            })
          ];
        };

      nixFiles = map (path: nixpkgs.lib.removePrefix "${toString ./.}/" (toString path)) (
        builtins.filter (path: nixpkgs.lib.hasSuffix ".nix" (toString path)) (
          nixpkgs.lib.filesystem.listFilesRecursive ./.
        )
      );

      perSystem = flake-utils.lib.eachSystem systems (
        system:
        let
          pkgs = pkgsBySystem.${system};
          local = localPkgsBySystem.${system};
          notionCliPkg = local.notion-cli;
          trueflowPkg = local.trueflow;
          piPkg = local.omp;
          oraclePkg = local.oracle;
          antigravityCliPkg = local.antigravity-cli;
          claudeCodePkg = local.claude-code;
          geminiCliPkg = local.gemini-cli;
          codexDesktopPkg = local.codex-desktop;
          wisprFlowPkg = local.wispr-flow;
          flowPkg = local.flow;
          voxtypePkg = local.voxtype;

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
            runtimeInputs = [
              pkgs.findutils
              pkgs.git
              pkgs.nixfmt
            ];
            text = ''
              has_path_arg=0
              after_double_dash=0
              for arg in "$@"; do
                if [ "$after_double_dash" -eq 1 ]; then
                  has_path_arg=1
                  break
                fi
                case "$arg" in
                --)
                  after_double_dash=1
                  ;;
                -*) ;;
                *)
                  has_path_arg=1
                  break
                  ;;
                esac
              done

              if [ "$has_path_arg" -eq 1 ]; then
                exec nixfmt "$@"
              fi

              if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                mapfile -d "" -t files < <(git ls-files -z -- '*.nix')
              else
                mapfile -d "" -t files < <(
                  find . -name '*.nix' \
                    -not -path './.git/*' \
                    -not -path './.direnv/*' \
                    -not -path './result*' \
                    -print0
                )
              fi

              if [ "''${#files[@]}" -eq 0 ]; then
                exit 0
              fi

              exec nixfmt "$@" "''${files[@]}"
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
                  nixfmt
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
            antigravity-cli = antigravityCliPkg;
            claude-code = claudeCodePkg;
            flow = flowPkg;
            gemini-cli = geminiCliPkg;
            gogcli = pkgs.gogcli;
            googleworkspace-cli = pkgs.gws;
            home-manager = home-manager.packages.${system}.home-manager;
            notion-cli = notionCliPkg;
            omp = piPkg;
            omp-phone = local.omp-phone;
            oracle = oraclePkg;
            pi = piPkg;
            secrets-lint = secretsLint;
            spotify-export = local.spotify-export;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            voxtype = voxtypePkg;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            codex-desktop = codexDesktopPkg;
            gemini = local.gemini;
            spotify = local.spotify;
            whatsapp = local.whatsapp;
            wispr-flow = wisprFlowPkg;
            xcodes = local.xcodes;
          };

          checks = {
            antigravity-cli = antigravityCliPkg;
            bootstrap-rust-tests = bootstrapRustTests;
            claude-code = claudeCodePkg;
            clean-stale-tests = cleanStaleTests;
            flow-smoke-tests = flowSmokeTests;
            gemini-cli = geminiCliPkg;
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
          pkgs,
          localPkgs ? null,
        }:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            inherit emacs-sops;
            pkgsPreGcc16 = pkgsPreGcc16For system;
          };
          modules = [
            module
            (mkHomePackagesModule { inherit localPkgs; })
            voxtype.homeManagerModules.default
          ]
          ++ extraModules;
        };

      mkMacosHome =
        {
          system,
          extraModules ? [ ],
          impureUser ? false,
        }:
        let
          bootstrapModules = nixpkgs.lib.optionals impureUser [
            (
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
              {
                home.username = nixpkgs.lib.mkForce bootstrapUser;
                home.homeDirectory = nixpkgs.lib.mkForce bootstrapHome;
              }
            )
          ];
        in
        mkHome {
          inherit system;
          module = ./home/hosts/jmq-macos.nix;
          pkgs = macosPkgsBySystem.${system};
          localPkgs = macosLocalPkgsBySystem.${system};
          extraModules = bootstrapModules ++ extraModules;
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
            (
              { pkgs, ... }:
              let
                localPkgs = mkLocalPackages { inherit pkgs; };
              in
              {
                _module.args.flowPkg = localPkgs.flow;
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
                      (mkHomePackagesModule { inherit localPkgs; })
                      voxtype.homeManagerModules.default
                    ];
                  };
              }
            )
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
        "macos-aarch64-bootstrap" = mkMacosHome {
          system = "aarch64-darwin";
          impureUser = true;
        };
        "work-macos-aarch64-bootstrap" = mkMacosHome {
          system = "aarch64-darwin";
          extraModules = [ ./home/hosts/work-macos.nix ];
          impureUser = true;
        };
        "linux-aarch64" = mkHome {
          system = "aarch64-linux";
          module = ./home/hosts/jmq-linux.nix;
          pkgs = unfreePkgsBySystem.aarch64-linux;
          localPkgs = unfreeLocalPkgsBySystem.aarch64-linux;
        };
        "linux-aarch64-lite" = mkHome {
          system = "aarch64-linux";
          module = ./home/hosts/jmq-linux.nix;
          extraModules = [ liteHomeModule ];
          pkgs = unfreePkgsBySystem.aarch64-linux;
          localPkgs = unfreeLocalPkgsBySystem.aarch64-linux;
        };
        "linux-x86_64" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
          pkgs = unfreePkgsBySystem.x86_64-linux;
          localPkgs = unfreeLocalPkgsBySystem.x86_64-linux;
        };
        "linux-x86_64-lite" = mkHome {
          system = "x86_64-linux";
          module = ./home/hosts/jmq-linux.nix;
          extraModules = [ liteHomeModule ];
          pkgs = unfreePkgsBySystem.x86_64-linux;
          localPkgs = unfreeLocalPkgsBySystem.x86_64-linux;
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
