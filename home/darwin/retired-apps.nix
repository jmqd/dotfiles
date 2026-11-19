{
  lib,
  pkgs,
  ...
}:
let
  # Hand-installed apps that Home Manager now provides. Each is trashed only
  # when its bundle ID matches, so an unrelated app at the same path survives.
  retired = [
    {
      path = "/Applications/WhatsApp.app";
      bundleId = "net.whatsapp.WhatsApp";
    }
    {
      path = "/Applications/Spotify.app";
      bundleId = "com.spotify.client";
    }
    {
      path = "/Applications/WezTerm.app";
      bundleId = "com.github.wez.wezterm";
    }
  ];

  retire = pkgs.writeShellApplication {
    name = "retire-apps";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      retire() {
        local app=$1 bundle_id=$2 identifier
        [[ -e "$app" || -L "$app" ]] || return 0
        if [[ ! -d "$app" || -L "$app" ]]; then
          printf 'Leaving %s: not a real application directory.\n' "$app" >&2
          return 0
        fi
        identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || identifier=""
        if [[ "$identifier" != "$bundle_id" ]]; then
          printf 'Leaving %s: bundle ID %s, expected %s.\n' "$app" "''${identifier:-unknown}" "$bundle_id" >&2
          return 0
        fi
        if /usr/bin/pgrep -qf "^$app/Contents/MacOS/"; then
          printf 'Leaving %s: it is running; quit it and switch again.\n' "$app" >&2
          return 0
        fi
        local name
        name=$(basename "$app" .app)
        if ! mv "$app" "$HOME/.Trash/$name.$(date +%s).app"; then
          printf 'Leaving %s: could not move it to the Trash.\n' "$app" >&2
          return 0
        fi
        printf 'Moved retired %s to the Trash.\n' "$app"
      }

      ${lib.concatMapStrings (a: ''
        retire ${lib.escapeShellArg a.path} ${lib.escapeShellArg a.bundleId}
      '') retired}
    '';
  };
in
{
  home.activation.retireApps = lib.hm.dag.entryAfter [ "copyApps" ] ''
    run ${lib.getExe retire}
  '';
}
