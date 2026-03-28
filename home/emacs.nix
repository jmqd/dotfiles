{ pkgs, ... }:
let
  emacsPkg =
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.emacs-macport
    else
      pkgs.emacs;
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
}
