{
  config,
  lib,
  pkgs,
  ...
}:
let
  package = pkgs.callPackage ../../pkgs/wispr-flow { };
  app = "${config.home.homeDirectory}/Applications/Wispr Flow.app";

  install = pkgs.writeShellApplication {
    name = "wispr-flow-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      readonly app=${lib.escapeShellArg app}
      readonly source=${lib.escapeShellArg "${package}/Applications/Wispr Flow.app"}
      readonly expected_version=${lib.escapeShellArg package.version}
      readonly bundle_id=com.electron.wispr-flow

      refuse() {
        printf '%s\n' "$*" >&2
        exit 1
      }

      installed_version=""
      if [[ -e "$app" || -L "$app" ]]; then
        [[ -d "$app" && ! -L "$app" ]] || refuse "$app must be a real application directory, not a symlink or file."
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") ||
          refuse "$app has no application metadata; refusing to replace it."
        [[ "$identifier" == "$bundle_id" ]] || refuse "Refusing to replace an unexpected application at $app ($identifier)."
        installed_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
      fi

      # The app updates itself in place; the Nix pin is a floor, never a downgrade.
      if [[ -n "$installed_version" ]] &&
        [[ "$(printf '%s\n%s\n' "$expected_version" "$installed_version" | sort -V | head -n1)" == "$expected_version" ]]; then
        printf 'Wispr Flow %s is installed at %s (Nix pin %s).\n' "$installed_version" "$app" "$expected_version"
        exit 0
      fi
      if [[ -n "$installed_version" ]] && /usr/bin/pgrep -qf "^$app/Contents/MacOS/Wispr Flow"; then
        printf 'Wispr Flow is running; quit it and switch again to install %s (currently %s).\n' "$expected_version" "$installed_version" >&2
        exit 0
      fi

      printf 'Installing Wispr Flow %s (currently %s) at %s.\n' "$expected_version" "''${installed_version:-absent}" "$app"
      staged="$(dirname "$app")/.Wispr Flow.app.staged"
      [[ ! -e "$staged" ]] || mv "$staged" "$HOME/.Trash/Wispr Flow.app.staged.$(date +%s)"
      mkdir -p "$(dirname "$app")"
      /usr/bin/ditto "$source" "$staged"
      # Writable so the in-app updater can replace the bundle.
      chmod -R u+w "$staged"
      /usr/bin/codesign --verify --deep --strict "$staged"
      if [[ -n "$installed_version" ]]; then
        mv "$app" "$HOME/.Trash/Wispr Flow $installed_version.$(date +%s).app"
      fi
      mv "$staged" "$app"
    '';
  };
in
{
  # Not in home.packages: Wispr Flow asks to be moved unless its bundle sits
  # directly in an Applications folder, which rules out copyApps' subfolder
  # and Nix-store symlinks.
  home.activation.installWisprFlow = lib.hm.dag.entryAfter [ "installPackages" ] ''
    run ${lib.getExe install}
  '';
}
