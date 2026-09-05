{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.omp-phone;
  environment = {
    OMP_PHONE_PORT = toString cfg.port;
    OMP_PHONE_STATE_DIR = cfg.stateDirectory;
  }
  // lib.optionalAttrs (cfg.publicUrl != null) {
    OMP_PHONE_PUBLIC_URL = cfg.publicUrl;
  };
in
{
  options.services.omp-phone = {
    enable = lib.mkEnableOption "private phone access to live OMP sessions";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./default.nix { };
      description = "The omp-phone companion package.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Loopback port proxied by Tailscale Serve.";
    };
    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://workstation.example.ts.net";
      description = "Exact Tailscale HTTPS origin. Null enables localhost development only.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.stateHome}/omp-phone";
      description = "Private runtime directory containing pairing credentials and push subscriptions.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.sessionVariables = environment;
    home.file.".omp/agent/extensions/omp-phone".source = "${cfg.package}/share/omp-phone/extension";

    launchd.agents.omp-phone = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      enable = true;
      config = {
        ProgramArguments = [
          "${cfg.package}/bin/omp-phone"
          "serve"
        ];
        EnvironmentVariables = environment;
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/omp-phone.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/omp-phone.log";
      };
    };

    systemd.user.services.omp-phone = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      Unit.Description = "OMP phone companion";
      Service = {
        ExecStart = "${cfg.package}/bin/omp-phone serve";
        Environment = lib.mapAttrsToList (name: value: "${name}=${value}") environment;
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
