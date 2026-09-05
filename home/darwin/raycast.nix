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
      # Launch through LaunchServices and keep the job alive with `-W`.
      # Use background launch, not `-j` (hidden): Raycast can receive its
      # hotkey while leaving the launcher off-screen after a hidden launch.
      ProgramArguments = [
        "/usr/bin/open"
        "-W"
        "-g"
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
