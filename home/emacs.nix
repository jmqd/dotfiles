{
  config,
  lib,
  pkgs,
  emacs-sops,
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  emacs31 =
    if pkgs ? emacs31 then
      pkgs.emacs31.overrideAttrs {
        version = "31.1";
        src = pkgs.fetchgit {
          url = "https://git.savannah.gnu.org/git/emacs.git";
          rev = "emacs-31.1";
          hash = "sha256-lFT5Vt49G17t/fRm5yppO5p9ui10I9JNJVaGO1GPZFI=";
        };
      }
    else
      null;
  # The Intel Darwin package set has no Emacs 31; retain its supported Mac port.
  emacsPkg =
    if emacs31 != null then
      emacs31
    else if isDarwin then
      pkgs.emacs-macport
    else
      pkgs.emacs;
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
    package = emacsPkg;
  };

  programs.emacs.extraPackages = epkgs: [
    (epkgs.trivialBuild {
      pname = "sops";
      version = "0.2.0";
      src = emacs-sops;
    })
  ];

  services.emacs = {
    enable = true;
    package = emacsPkg;
  };

  launchd.agents.emacs.config.EnvironmentVariables =
    lib.mkIf pkgs.stdenv.hostPlatform.isDarwin latexExportEnvironment;

  home.file = {
    ".emacs.d/handcrafted-loader.el".source = ../emacs/handcrafted-loader.el;
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
