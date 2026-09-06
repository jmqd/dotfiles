{
  config,
  lib,
  pkgs,
  ...
}:
let
  inventory = import ./yubikeys.nix;
  credentials = lib.concatMap (device: device.webauthn or [ ]) (builtins.attrValues inventory);
in
{
  imports = [ ../projects/omp-phone/home-module.nix ];

  services.omp-phone = {
    enable = lib.mkDefault config.jmq.packageSets.customCli.enable;
    credentialsFile = pkgs.writeText "omp-phone-credentials.json" (builtins.toJSON credentials);
  };
}
