{ lib, pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ForwardAgent = "no";
        AddKeysToAgent = "no";
        Compression = "no";
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = "no";
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };

      "github.com" = {
        AddKeysToAgent = "yes";
        ControlMaster = "auto";
        ControlPath = "~/.ssh/cm-%C";
        ControlPersist = "10m";
        IdentitiesOnly = "yes";
        IdentityFile = [ "~/.ssh/id_ed25519" ];
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        UseKeychain = "yes";
      };

      "jmws" = {
        ControlMaster = "auto";
        ControlPath = "~/.ssh/cm-%C";
        ControlPersist = "10m";
      };
    };
  };
}
