{ lib, pkgs, ... }:
{
  imports = [ ../darwin ];

  home.username = "jmq";
  home.homeDirectory = "/Users/jmq";

  services.omp-phone = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
    publicUrl = "https://jordans-macbook-pro.taild6d9b.ts.net";
    allowedTailnetUsers = [ "j@jm.dev" ];
    tailnetCapability = "jm.dev/cap/omp-phone";
  };
}
