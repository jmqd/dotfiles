{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jmq.xcode;

  install = pkgs.writeShellApplication {
    name = "xcode-install";
    runtimeInputs = [ pkgs.xcodes ];
    text = ''
      readonly version=${lib.escapeShellArg cfg.version}

      # Any full Xcode counts, including App Store and beta installs: this
      # bootstraps a machine and never upgrades or replaces an existing one.
      for app in /Applications/Xcode*.app; do
        [[ -f "$app/Contents/Info.plist" ]] || continue
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || continue
        if [[ "$identifier" == com.apple.dt.Xcode ]]; then
          printf 'Xcode is installed at %s; not installing %s.\n' "$app" "$version"
          exit 0
        fi
      done

      # Apple's download needs an Apple ID sign-in and two-factor code, and
      # xcodes asks for the macOS password to finish; none can be answered
      # without a terminal.
      if [[ ! -t 0 ]]; then
        printf 'No Xcode installed and no terminal for the Apple ID prompts; run xcode-install to install Xcode %s.\n' "$version" >&2
        exit 1
      fi

      printf 'Installing Xcode %s with xcodes; this downloads several GB from Apple.\n' "$version"
      xcodes install "$version" --select --aria2 ${lib.escapeShellArg (lib.getExe' pkgs.aria2 "aria2c")}
    '';
  };
in
{
  options.jmq.xcode = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install Xcode with xcodes during activation when /Applications has no
        Xcode. Apple's download needs an Apple ID, so the first install
        prompts for it.
      '';
    };

    version = lib.mkOption {
      type = lib.types.str;
      # Xcode 27 requires macOS 26.6.
      default = "26.6";
      description = "Xcode version installed when none is present.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      install
      pkgs.xcodes
    ];

    # A failed download must not abort the rest of the switch; the retry is
    # one command.
    home.activation.installXcode = lib.hm.dag.entryAfter [ "installPackages" ] ''
      if ! run ${lib.getExe install}; then
        echo "warning: Xcode was not installed; run xcode-install to retry." >&2
      fi
    '';
  };
}
