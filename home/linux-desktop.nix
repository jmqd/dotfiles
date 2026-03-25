{ ... }:
{
  home.file = {
    ".Xmodmap".source = ../.Xmodmap;
    ".Xresources".source = ../.Xresources;

    ".i3".source = ../.i3;
    ".config/i3status".source = ../.config/i3status;

    ".config/autorandr/default/config".source = ../autorandr.profile;
  };
}
