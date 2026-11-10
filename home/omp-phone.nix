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
    # Without publicUrl no enrolled key can sign in, so the daemon would only
    # listen on localhost and collect every OMP transcript for nobody.
    enable = lib.mkDefault (
      config.jmq.packageSets.customCli.enable && config.services.omp-phone.publicUrl != null
    );
    credentialsFile = pkgs.writeText "omp-phone-credentials.json" (builtins.toJSON credentials);
  };
}
