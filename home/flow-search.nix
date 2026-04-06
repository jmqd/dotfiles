{ config, lib, pkgs, ... }:
let
  flowSearchStateDir = "${config.home.homeDirectory}/.local/share/flow-search";
  flowSearchIndexDir = "${flowSearchStateDir}/zoekt/index";
in
{
  home.packages = [ pkgs.zoekt ];

  home.activation.createFlowSearchDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p ${lib.escapeShellArg flowSearchIndexDir}
    mkdir -p ${lib.escapeShellArg "${flowSearchStateDir}/metadata"}
  '';

  systemd.user.services.flow-search-zoekt = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Local Zoekt webserver for flow search";
      After = [ "default.target" ];
    };
    Service = {
      ExecStart = "${pkgs.zoekt}/bin/zoekt-webserver -index ${lib.escapeShellArg flowSearchIndexDir} -listen 127.0.0.1:6070";
      Restart = "on-failure";
      WorkingDirectory = flowSearchStateDir;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  launchd.agents.flow-search-zoekt = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.zoekt}/bin/zoekt-webserver"
        "-index"
        flowSearchIndexDir
        "-listen"
        "127.0.0.1:6070"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      WorkingDirectory = flowSearchStateDir;
      StandardOutPath = "/tmp/flow-search-zoekt.log";
      StandardErrorPath = "/tmp/flow-search-zoekt.err.log";
    };
  };
}
