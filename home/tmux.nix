{ pkgs, ... }:
{
  programs.tmux = {
    enable = true;
    package = pkgs.tmux;
    keyMode = "vi";
    historyLimit = 10000;
    escapeTime = 15;
    terminal = "screen-256color";

    extraConfig = ''
      # Custom pane and window navigation using ijkl/h/l.
      bind j select-pane -L
      bind k select-pane -D
      bind i select-pane -U
      bind l select-pane -R
      bind-key -r C-h select-window -t :-
      bind-key -r C-l select-window -t :+

      ####################
      ## > Look and feel
      ####################

      # status line
      set -g status-justify left
      set -g status-interval 2

      # messaging
      set -g message-command-style "fg=blue,bg=black"

      # Info on left (I don't have a session display for now)
      set -g status-left ""

      # loud or quiet?
      set-option -g visual-activity off
      set-option -g visual-bell off
      set-option -g visual-silence off
      set-window-option -g monitor-activity off
      set-option -g bell-action none

      # The modes {
      setw -g clock-mode-colour colour135
      setw -g mode-style "fg=colour196,bg=colour238,bold"

      # }
      # The panes {

      set -g pane-border-style "fg=colour238,bg=colour235"
      set -g pane-active-border-style "fg=colour51,bg=colour236"

      # }
      # The statusbar {

      set -g status-position bottom
      set -g status-style "fg=colour137,bg=colour234,dim"
      set -g status-left ""
      set -g status-right "#[fg=colour233,bg=colour241,bold] %Y-%d-%m #[fg=colour233,bg=colour245,bold] %H:%M:%S "
      set -g status-right-length 50
      set -g status-left-length 20

      setw -g window-status-current-style "fg=colour81,bg=colour238,bold"
      setw -g window-status-current-format " #I#[fg=colour250]:#[fg=colour255]#W#[fg=colour50]#F "

      setw -g window-status-style "fg=colour138,bg=colour235"
      setw -g window-status-format " #I#[fg=colour237]:#[fg=colour250]#W#[fg=colour244]#F "

      setw -g window-status-bell-style "fg=colour255,bg=colour1,bold"

      # }
      # The messages {

      set -g message-style "fg=colour232,bg=colour166,bold"

      # }
    '';
  };
}
