{
  config,
  lib,
  pkgs,
  ...
}:
let
  emacsPkg = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.emacs-macport else pkgs.emacs;
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
