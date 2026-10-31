{
  config,
  lib,
  pkgs,
  emacs-sops,
  ...
}:
let
  handcraftedBinDir = "${config.home.homeDirectory}/.local/bin";
  handcraftedClient = "${handcraftedBinDir}/emacs-handcrafted-client";
  latexExportEnvironment = {
    LANG = config.home.sessionVariables.LANG;
    LC_CTYPE = config.home.sessionVariables.LC_CTYPE;
    OSFONTDIR = config.home.sessionVariables.OSFONTDIR;
  };
in
{
  programs.emacs = {
    enable = true;
    package = pkgs.emacs31;
  };

  # Every package the handcrafted config loads, pinned by flake.lock. Emacs
  # never downloads packages itself (emacs/lisp/core/bootstrap.el).
  programs.emacs.extraPackages = epkgs: [
    (epkgs.trivialBuild {
      pname = "sops";
      version = "0.2.1";
      src = emacs-sops;
    })
    epkgs.avy
    epkgs.cape
    epkgs.consult
    epkgs.corfu
    epkgs.dap-mode
    epkgs.embark
    epkgs.embark-consult
    epkgs.evil
    epkgs.evil-collection
    epkgs.exec-path-from-shell
    epkgs.general
    epkgs.go-mode
    epkgs.htmlize
    epkgs.kind-icon
    epkgs.langtool
    epkgs.magit
    epkgs.marginalia
    epkgs.markdown-mode
    epkgs.nix-mode
    epkgs.orderless
    epkgs.ox-reveal
    epkgs.plantuml-mode
    epkgs.rust-mode
    epkgs.vertico
    epkgs.wgrep
    epkgs.yaml-mode
    epkgs.yasnippet
    epkgs.yasnippet-snippets
    epkgs.zig-mode
  ];

  # Defaults to programs.emacs.finalPackage, which carries extraPackages such
  # as sops; the bare pkgs.emacs31 would abort init on (use-package sops).
  services.emacs.enable = true;

  launchd.agents.emacs.config.EnvironmentVariables =
    lib.mkIf pkgs.stdenv.hostPlatform.isDarwin latexExportEnvironment;

  home.file = {
    ".emacs.d/early-init.el".source = ../emacs/early-init.el;
    ".emacs.d/init.el".source = ../emacs/init.el;
    ".emacs.d/lisp".source = ../emacs/lisp;
    "Applications/Emacs.app".source = "${config.programs.emacs.finalPackage}/Applications/Emacs.app";
    ".local/bin/emacs-handcrafted".source = ../bin/emacs-handcrafted;
    ".local/bin/emacs-handcrafted-client".source = ../bin/emacs-handcrafted-client;
    ".local/bin/emacs-handcrafted-daemon".source = ../bin/emacs-handcrafted-daemon;
  };

  home.sessionPath = [ handcraftedBinDir ];

  home.sessionVariables = {
    EDITOR = handcraftedClient;
    VISUAL = handcraftedClient;
    EMACS_HANDCRAFTED_EMACS_BIN = "${config.programs.emacs.finalPackage}/bin/emacs";
    EMACS_HANDCRAFTED_EMACSCLIENT_BIN = "${config.programs.emacs.finalPackage}/bin/emacsclient";
  };
}
