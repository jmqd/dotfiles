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
      # Launch through LaunchServices; `-W` ties the job's lifetime to the
      # app so KeepAlive relaunches Raycast after a crash or quit.
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
      KeepAlive = true;
      StandardOutPath = "/tmp/raycast.log";
      StandardErrorPath = "/tmp/raycast.err.log";
    };
  };

  # Stop unmanaged or previous-generation instances before Home Manager
  # reloads the tracked LaunchServices job. Boot the job out first: Home
  # Manager skips agents whose plist is unchanged and still loaded, so a
  # bare kill would leave no Raycast running, and with KeepAlive the old
  # job would respawn the old app mid-switch. Unloaded, the job is always
  # bootstrapped again by setupLaunchAgents.
  home.activation.stopStaleRaycast = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
    run /bin/launchctl bootout "gui/$(/usr/bin/id -u)/org.nix-community.home.raycast" >/dev/null 2>&1 || true
    run /usr/bin/killall Raycast >/dev/null 2>&1 || true
  '';

  # RunAtLoad/KeepAlive spawns are "speculative": launchd may defer them
  # indefinitely (e.g. under load), leaving the freshly bootstrapped job
  # with zero runs and Option-Space unbound. Demand the launch explicitly.
  home.activation.startRaycast = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    run /bin/launchctl kickstart "gui/$(/usr/bin/id -u)/org.nix-community.home.raycast"
  '';
}
