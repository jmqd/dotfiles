{ config, lib, ... }:
let
  configPath =
    if config.xdg.enable then
      "${lib.removePrefix config.home.homeDirectory config.xdg.configHome}/aerospace/aerospace.toml"
    else
      ".aerospace.toml";
in
{
  programs.aerospace = {
    enable = true;
    launchd.enable = true;

    settings = {
      default-root-container-layout = "tiles";
      default-root-container-orientation = "auto";

      gaps = {
        inner.horizontal = 8;
        inner.vertical = 8;
        outer.left = 8;
        outer.bottom = 8;
        outer.top = 8;
        outer.right = 8;
      };

      mode.main.binding = {
        "alt-enter" = "exec-and-forget open -na WezTerm";
        "alt-q" = "close";

        "alt-j" = "focus left";
        "alt-k" = "focus down";
        "alt-i" = "focus up";
        "alt-l" = "focus right";

        "alt-left" = "focus left";
        "alt-down" = "focus down";
        "alt-up" = "focus up";
        "alt-right" = "focus right";

        "alt-shift-j" = "move left";
        "alt-shift-k" = "move down";
        "alt-shift-i" = "move up";
        "alt-shift-l" = "move right";

        "alt-shift-left" = "move left";
        "alt-shift-down" = "move down";
        "alt-shift-up" = "move up";
        "alt-shift-right" = "move right";

        "alt-shift-h" = "split horizontal";
        "alt-shift-v" = "split vertical";

        "alt-f" = "fullscreen";
        "alt-s" = "layout v_accordion";
        "alt-w" = "layout h_accordion";
        "alt-e" = "layout tiles horizontal vertical";
        "alt-shift-space" = "layout floating tiling";

        "alt-tab" = "workspace next";
        "alt-shift-tab" = "workspace prev";

        "alt-1" = "workspace 1";
        "alt-2" = "workspace 2";
        "alt-3" = "workspace 3";
        "alt-4" = "workspace 4";
        "alt-5" = "workspace 5";
        "alt-6" = "workspace 6";
        "alt-7" = "workspace 7";
        "alt-8" = "workspace 8";
        "alt-9" = "workspace 9";
        "alt-0" = "workspace 10";

        "alt-shift-1" = "move-node-to-workspace 1";
        "alt-shift-2" = "move-node-to-workspace 2";
        "alt-shift-3" = "move-node-to-workspace 3";
        "alt-shift-4" = "move-node-to-workspace 4";
        "alt-shift-5" = "move-node-to-workspace 5";
        "alt-shift-6" = "move-node-to-workspace 6";
        "alt-shift-7" = "move-node-to-workspace 7";
        "alt-shift-8" = "move-node-to-workspace 8";
        "alt-shift-9" = "move-node-to-workspace 9";
        "alt-shift-0" = "move-node-to-workspace 10";

        "alt-shift-c" = "reload-config";
        "alt-r" = "mode resize";
      };

      mode.resize.binding = {
        j = "resize width +50";
        l = "resize width -50";
        i = "resize height +50";
        k = "resize height -50";

        left = "resize width -50";
        right = "resize width +50";
        up = "resize height -50";
        down = "resize height +50";

        enter = "mode main";
        esc = "mode main";
      };
    };
  };

  home.file.${configPath}.onChange = lib.mkForce ''
    if /usr/bin/pgrep -x AeroSpace >/dev/null 2>&1; then
      echo "AeroSpace config changed, reloading..."
      ${lib.getExe config.programs.aerospace.package} reload-config || \
        echo "AeroSpace reload failed; continuing." >&2
    else
      echo "AeroSpace config changed, but AeroSpace is not running; skipping reload." >&2
    fi
  '';
}
