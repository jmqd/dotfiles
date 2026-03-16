{ pkgs, ... }:
{
  programs.gpg = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
    enableZshIntegration = true;
    defaultCacheTtl = 1800;
    maxCacheTtl = 7200;
    pinentry.package =
      if pkgs.stdenv.isDarwin && pkgs ? pinentry_mac then
        pkgs.pinentry_mac
      else
        pkgs.pinentry-curses;
  };
}
