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
      # Let launchd own the real app process. Launching through `open` exits
      # immediately and leaves old Nix-store versions alive across switches;
      # multiple Raycast processes then compete for the global hotkey.
      ProgramArguments = [ "${raycastApp}/Contents/MacOS/Raycast" ];
      ProcessType = "Interactive";
      RunAtLoad = true;
      StandardOutPath = "/tmp/raycast.log";
      StandardErrorPath = "/tmp/raycast.err.log";
    };
  };

  # Stop unmanaged or previous-generation instances before Home Manager
  # reloads this agent. The direct launchd process then starts exactly once.
  home.activation.stopStaleRaycast = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
    /usr/bin/killall Raycast >/dev/null 2>&1 || true
  '';
}
