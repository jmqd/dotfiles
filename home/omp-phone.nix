{ config, lib, ... }:
{
  imports = [ ../projects/omp-phone/home-module.nix ];

  services.omp-phone.enable = lib.mkDefault config.jmq.packageSets.customCli.enable;
}
