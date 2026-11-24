{
  lib,
  pkgs,
  ...
}:
{
  # Determinate Nix on Darwin defaults to eval-cores = 1 in /etc/nix/nix.conf
  # and accepts eval-cores = 0 cleanly in user config without warnings.
  # Upstream Linux Nix does not recognize eval-cores, and daemon-restricted
  # settings (download-buffer-size, http-connections, max-substitution-jobs)
  # emit untrusted-user warnings when set outside /etc/nix/nix.custom.conf or
  # NixOS's nix.settings.
  xdg.configFile."nix/nix.conf" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    text = ''
      eval-cores = 0
    '';
  };
}
