{ config, pkgs, ... }:
let
  emacsPkg =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.emacs-macport
    else
      pkgs.emacs;
  handcraftedBinDir = "${config.home.homeDirectory}/.local/bin";
  handcraftedClient = "${handcraftedBinDir}/emacs-handcrafted-client";
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

  home.file = {
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
