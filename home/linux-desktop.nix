{
  config,
  lib,
  pkgs,
  ...
}:
let
  homeDir = config.home.homeDirectory;
  cfg = config.jmq.linux.desktop;
  x11vncTailscale = pkgs.writeShellScript "x11vnc-tailscale" ''
    tailscale_ip="$(${pkgs.tailscale}/bin/tailscale ip -4)"
    exec ${pkgs.x11vnc}/bin/x11vnc \
      -display :0 \
      -auth ${homeDir}/.Xauthority \
      -rfbauth ${homeDir}/.config/x11vnc/passwd \
      -listen "$tailscale_ip" \
      -no6 \
      -noipv6 \
      -listenv6 ::1 \
      -rfbport 5900 \
      -forever \
      -shared \
      -repeat \
      -noxdamage
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.file = {
      ".Xmodmap".source = ../.Xmodmap;
      ".Xresources".source = ../.Xresources;

      ".i3".source = ../.i3;
      ".config/i3status".source = ../.config/i3status;

      ".config/autorandr/default/config".source = ../autorandr.profile;
    };

    home.packages = [ pkgs.x11vnc ];

    systemd.user.services.x11vnc = {
      Unit = {
        Description = "Share the active X11 desktop over VNC";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Environment = [
          "DISPLAY=:0"
          "XAUTHORITY=${homeDir}/.Xauthority"
        ];
        ExecStart = "${x11vncTailscale}";
        ExecStartPre = "${pkgs.coreutils}/bin/test -r ${homeDir}/.config/x11vnc/passwd";
        Restart = "on-failure";
        RestartSec = "5s";
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
