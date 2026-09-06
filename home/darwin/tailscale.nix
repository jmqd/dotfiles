{
  config,
  lib,
  pkgs,
  ...
}:
let
  version = "1.102.3";
  installer = pkgs.fetchurl {
    url = "https://pkgs.tailscale.com/stable/Tailscale-${version}-macos.pkg";
    hash = "sha256-oRYbUUbWXslFGZ9rt0HIa3BXxPGurkHhDXwIIIBktks=";
  };
  app = "/Applications/Tailscale.app";

  # Use the installed, approved app, not a second daemon or a Nix-store GUI.
  cli = pkgs.writeShellApplication {
    name = "tailscale";
    text = ''
      if [[ ! -x "${app}/Contents/MacOS/Tailscale" ]]; then
        echo "Tailscale is not installed. Run tailscale-install after completing the App Store migration." >&2
        exit 1
      fi
      exec "${app}/Contents/MacOS/Tailscale" "$@"
    '';
  };

  install = pkgs.writeShellApplication {
    name = "tailscale-install";
    text = ''
      readonly app=${lib.escapeShellArg app}
      readonly home_dir=${lib.escapeShellArg config.home.homeDirectory}
      readonly expected_version=${lib.escapeShellArg version}
      readonly package=${lib.escapeShellArg (toString installer)}
      check_only=false
      case "$*" in
        --check) check_only=true ;;
        --help|-h)
          printf '%s\n' \
            "tailscale-install [--check]" \
            "" \
            "Install the Nix-pinned Tailscale standalone GUI and CLI ($expected_version)." \
            "--check only reports installation state; it never installs or requests sudo." \
            "" \
            "First remove the App Store app, empty Trash, and reboot." \
            "Installation uses Apple's signed package installer and may restart Tailscale." \
            "macOS extension approval and Tailscale sign-in may still be required."
          exit 0
          ;;
        "") ;;
        *) echo "Usage: tailscale-install [--check]" >&2; exit 2 ;;
      esac

      refuse() {
        printf '%s\n' "$*" >&2
        exit 1
      }

      installed_version=""
      if [[ -e "$app" || -L "$app" ]]; then
        [[ -d "$app" && ! -L "$app" ]] || refuse "$app must be a real application directory, not a symlink or file."
        [[ -f "$app/Contents/Info.plist" ]] || refuse "$app has no application metadata; refusing to replace it."
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
        case "$identifier" in
          io.tailscale.ipn.macos)
            refuse "App Store Tailscale is still installed at $app. Quit it, remove it, empty Trash, and reboot before running tailscale-install. No changes made."
            ;;
          io.tailscale.ipn.macsys) ;;
          *) refuse "Refusing to replace an unexpected application at $app ($identifier)." ;;
        esac
        installed_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
      fi

      for duplicate in "$home_dir/Applications/Tailscale.app" "$home_dir/Applications/Home Manager Apps/Tailscale.app"; do
        [[ ! -e "$duplicate" && ! -L "$duplicate" ]] || refuse "Remove the duplicate Tailscale application at $duplicate before using the standalone installation."
      done
      app_store_matches=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'io.tailscale.ipn.macos'")
      [[ -z "$app_store_matches" ]] || refuse "Spotlight still reports an App Store installation. Resolve it before installing: $app_store_matches"
      if /usr/bin/pgrep -x tailscaled >/dev/null; then
        refuse "A separate tailscaled daemon is running. Do not run it alongside the standalone GUI."
      fi
      if [[ -z "$installed_version" ]] && /usr/bin/pgrep -x IPNExtension >/dev/null; then
        refuse "A Tailscale network extension is still running without the app. Complete the uninstall and reboot first."
      fi

      if [[ "$installed_version" == "$expected_version" ]]; then
        printf 'Tailscale standalone %s is installed at %s.\n' "$expected_version" "$app"
        exit 0
      fi
      printf 'Tailscale standalone: installed=%s, Nix pin=%s.\n' "''${installed_version:-absent}" "$expected_version"
      if "$check_only"; then
        exit 1
      fi

      # Keep the official installer intact: its scripts manage app replacement,
      # LaunchServices, the bundled CLI/manpages, and application launch.
      /usr/sbin/pkgutil --check-signature "$package"
      /usr/sbin/spctl --assess --type install "$package"
      printf 'Installing standalone %s (currently %s); this can restart the VPN.\n' "$expected_version" "''${installed_version:-absent}"
      /usr/bin/sudo /usr/sbin/installer -pkg "$package" -target /
      [[ -x "$app/Contents/MacOS/Tailscale" ]] || refuse "Installation did not produce the Tailscale CLI."
      installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
      installed_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
      [[ "$installed_id" == io.tailscale.ipn.macsys && "$installed_version" == "$expected_version" ]] || refuse "Installed app does not match the pinned standalone version."
      /usr/bin/codesign --verify --deep --strict "$app"
      echo "Installed. Approve the system extension and sign in if prompted; then run tailscale status."
      echo "Check the node name/IP before configuring OMP Serve."
    '';
  };
in
{
  # Deliberately no Applications output: Home Manager's user-app copying cannot
  # replace the official system-level installer for this VPN extension.
  home.packages = [
    cli
    install
  ];

  home.activation.checkTailscaleInstallation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! ${lib.getExe install} --check; then
      echo "Tailscale installation needs attention. See README's macOS Tailscale migration steps; run tailscale-install when ready."
    fi
  '';
}
