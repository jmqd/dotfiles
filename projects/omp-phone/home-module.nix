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
    OMP_PHONE_TAILNET_USERS = lib.concatStringsSep "," cfg.allowedTailnetUsers;
    OMP_PHONE_TAILNET_CAPABILITY = cfg.tailnetCapability;
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
      example = "https://workstation.example.ts.net/omp/";
      description = "Tailscale HTTPS URL ending in /omp/. Null enables localhost development at /omp/ only.";
    };
    allowedTailnetUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[^,[:space:]]+");
      default = [ ];
      example = [ "you@example.com" ];
      description = "Exact Tailscale login allowlist required in HTTPS mode, in addition to browser pairing.";
    };
    tailnetCapability = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "example.com/cap/omp-phone";
      description = "Serve app capability with access=true, granted only to direct tailnet members. Required in HTTPS mode.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.stateHome}/omp-phone";
      description = "Private runtime directory containing pairing credentials and push subscriptions.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.publicUrl == null
          || !lib.hasPrefix "https://" cfg.publicUrl
          || (cfg.allowedTailnetUsers != [ ] && cfg.tailnetCapability != "");
        message = "omp-phone HTTPS requires allowedTailnetUsers and a member-only tailnetCapability.";
      }
    ];
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
        Umask = 63; # 0077
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
