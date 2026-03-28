{ config, lib, pkgs, ... }:
let
  raycastExecutable = "${pkgs.raycast}/Applications/Raycast.app/Contents/MacOS/Raycast";
in
{
  home.packages = [ pkgs.raycast ];

  launchd.agents.raycast = {
    enable = true;
    config = {
      Program = raycastExecutable;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/raycast.log";
      StandardErrorPath = "/tmp/raycast.err.log";
    };
  };

  home.activation.disableSpotlightHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export HOME=${lib.escapeShellArg config.home.homeDirectory}

    plist="$HOME/Library/Preferences/com.apple.symbolichotkeys.plist"
    buddy=/usr/libexec/PlistBuddy

    if [[ ! -f "$plist" ]]; then
      /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict
    fi

    if ! "$buddy" -c "Print :AppleSymbolicHotKeys" "$plist" >/dev/null 2>&1; then
      "$buddy" -c "Add :AppleSymbolicHotKeys dict" "$plist"
    fi

    disable_hotkey() {
      local key="$1"
      if ! "$buddy" -c "Print :AppleSymbolicHotKeys:''${key}" "$plist" >/dev/null 2>&1; then
        "$buddy" -c "Add :AppleSymbolicHotKeys:''${key} dict" "$plist"
      fi
      "$buddy" -c "Delete :AppleSymbolicHotKeys:''${key}:enabled" "$plist" >/dev/null 2>&1 || true
      "$buddy" -c "Add :AppleSymbolicHotKeys:''${key}:enabled bool false" "$plist"
    }

    # 64 = Spotlight search, 65 = Finder search window.
    disable_hotkey 64
    disable_hotkey 65

    /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
  '';
}
