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

  # Google Workspace accounts need a project for Gemini Code Assist OAuth (omp's
  # google-gemini-cli login). Host-scoped so work tooling never defaults to it.
  home.sessionVariables.GOOGLE_CLOUD_PROJECT = "jm-dev-ws";
}
