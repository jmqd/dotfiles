{
  config,
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
      ProgramArguments = [
        "/usr/bin/open"
        "-gj"
        raycastApp
      ];
      RunAtLoad = true;
      StandardOutPath = "/tmp/raycast.log";
      StandardErrorPath = "/tmp/raycast.err.log";
    };
  };

  # Raycast has no supported noninteractive hotkey setter. Configure its
  # global hotkey as Command-Space once in Raycast Settings > General.
  home.activation.configureSpotlightHotkey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export HOME=${lib.escapeShellArg config.home.homeDirectory}

    domain=com.apple.symbolichotkeys
    buddy=/usr/libexec/PlistBuddy
    tmp_dir="$(/usr/bin/mktemp -d "''${TMPDIR:-/tmp}/jmq-symbolic-hotkeys.XXXXXX")"
    tmp_plist="$tmp_dir/preferences.plist"
    changed=false

    if ! /usr/bin/defaults export "$domain" "$tmp_plist" >/dev/null 2>&1; then
      /usr/bin/defaults write "$domain" AppleSymbolicHotKeys -dict
      /usr/bin/defaults export "$domain" "$tmp_plist" >/dev/null
    fi

    add_standard_value() {
      local key="$1"
      local modifiers="$2"

      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value dict" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value:type string standard" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value:parameters array" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value:parameters:0 integer 32" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value:parameters:1 integer 49" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:value:parameters:2 integer $modifiers" "$tmp_plist"
    }

    # 64 is Spotlight search. Preserve its existing key binding so it can be
    # restored later, but make a complete standard record when none exists.
    if ! "$buddy" -c "Print :AppleSymbolicHotKeys:64" "$tmp_plist" >/dev/null 2>&1; then
      "$buddy" -c "Add :AppleSymbolicHotKeys:64 dict" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:64:enabled bool false" "$tmp_plist"
      add_standard_value 64 1048576
      changed=true
    else
      if ! "$buddy" -c "Print :AppleSymbolicHotKeys:64:value" "$tmp_plist" >/dev/null 2>&1; then
        add_standard_value 64 1048576
        changed=true
      fi

      enabled="$("$buddy" -c "Print :AppleSymbolicHotKeys:64:enabled" "$tmp_plist" 2>/dev/null || true)"
      if [[ "$enabled" != "false" ]]; then
        "$buddy" -c "Delete :AppleSymbolicHotKeys:64:enabled" "$tmp_plist" >/dev/null 2>&1 || true
        "$buddy" -c "Add :AppleSymbolicHotKeys:64:enabled bool false" "$tmp_plist"
        changed=true
      fi
    fi

    # The previous activation created an incomplete disabled Finder-search
    # record (65) when macOS had none. Repair only that recognizable state;
    # otherwise leave the unrelated Option-Command-Space shortcut untouched.
    if "$buddy" -c "Print :AppleSymbolicHotKeys:65" "$tmp_plist" >/dev/null 2>&1 \
      && ! "$buddy" -c "Print :AppleSymbolicHotKeys:65:value" "$tmp_plist" >/dev/null 2>&1 \
      && [[ "$("$buddy" -c "Print :AppleSymbolicHotKeys:65:enabled" "$tmp_plist" 2>/dev/null || true)" == "false" ]]; then
      add_standard_value 65 1572864
      "$buddy" -c "Delete :AppleSymbolicHotKeys:65:enabled" "$tmp_plist"
      "$buddy" -c "Add :AppleSymbolicHotKeys:65:enabled bool true" "$tmp_plist"
      changed=true
    fi

    if $changed; then
      /usr/bin/defaults import "$domain" "$tmp_plist" >/dev/null
      /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
    fi

    ${pkgs.coreutils}/bin/unlink "$tmp_plist"
    /bin/rmdir "$tmp_dir"
  '';
}
