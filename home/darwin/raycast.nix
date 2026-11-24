{
  config,
  lib,
  pkgs,
  ...
}:
let
  raycastApp = "${pkgs.raycast}/Applications/Raycast.app";
  raycastStateCheck = ''
    uid="$(/usr/bin/id -u)"
    job="gui/$uid/org.nix-community.home.raycast"
    expected_app=${lib.escapeShellArg raycastApp}
    expected_bin="$expected_app/Contents/MacOS/Raycast"
    stamp_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/home-manager"
    stamp_file="$stamp_dir/raycast-app.stamp"
    recorded=""
    if [[ -r "$stamp_file" ]]; then
      IFS= read -r recorded < "$stamp_file" || true
    fi
  '';
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
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/raycast.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/raycast.err.log";
    };
  };

  # Stop unmanaged or previous-generation instances before Home Manager
  # reloads the tracked LaunchServices job, skipping the restart when the exact
  # target Raycast bundle is already running under the loaded launchd job.
  home.activation.stopStaleRaycast = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
    ${raycastStateCheck}
    if [[ "$recorded" == "$expected_app" ]] \
      && /bin/launchctl print "$job" >/dev/null 2>&1 \
      && /usr/bin/pgrep -qf "^$expected_bin"; then
      :
    else
      run /bin/launchctl bootout "$job" >/dev/null 2>&1 || true
      run /usr/bin/killall Raycast >/dev/null 2>&1 || true
    fi
  '';

  # RunAtLoad/KeepAlive spawns are "speculative": launchd may defer them
  # indefinitely (e.g. under load), leaving the freshly bootstrapped job
  # with zero runs and Option-Space unbound. Demand the launch explicitly
  # whenever Raycast was updated or is not running.
  home.activation.startRaycast = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    ${raycastStateCheck}
    if [[ "$recorded" == "$expected_app" ]] \
      && /bin/launchctl print "$job" >/dev/null 2>&1 \
      && /usr/bin/pgrep -qf "^$expected_bin"; then
      :
    else
      run /bin/launchctl kickstart "$job"
      if [[ -z "''${DRY_RUN:-}" ]]; then
        mkdir -p "$stamp_dir"
        printf '%s\n' "$expected_app" > "$stamp_file"
      fi
    fi
  '';
}
