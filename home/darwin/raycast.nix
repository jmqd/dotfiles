{
  lib,
  pkgs,
  ...
}:
let
  raycastApp = "${pkgs.raycast}/Applications/Raycast.app";
in
{
  home.packages = [ pkgs.raycast ];

  launchd.agents.raycast = {
    enable = true;
    config = {
      # Launch through LaunchServices so Raycast registers as a GUI app. `-W`
      # keeps the launchd job alive while `-g -j` avoids showing the launcher
      # at login.
      ProgramArguments = [
        "/usr/bin/open"
        "-W"
        "-gj"
        raycastApp
      ];
      ProcessType = "Interactive";
      RunAtLoad = true;
      StandardOutPath = "/tmp/raycast.log";
      StandardErrorPath = "/tmp/raycast.err.log";
    };
  };

  # Stop unmanaged or previous-generation instances before Home Manager
  # reloads the tracked LaunchServices job.
  home.activation.stopStaleRaycast = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
    /usr/bin/killall Raycast >/dev/null 2>&1 || true
  '';
}
