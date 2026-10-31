{ ... }:
{
  imports = [ ../darwin ];

  home.username = "jmq";
  home.homeDirectory = "/Users/jmq";

  services.omp-phone = {
    publicUrl = "https://jordans-macbook-pro-1.taild6d9b.ts.net/omp/";
    allowedTailnetUsers = [ "j@jm.dev" ];
    tailnetCapability = "jm.dev/cap/omp-phone";
  };
}
