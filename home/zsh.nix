{ ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history.extended = true;

    sessionVariables = {
      EDITOR = "emacs";
      TERM = "xterm-256color";
    };

    shellAliases = {
      g = "git";
      ga = "git add";
      gb = "git branch";
      gc = "git commit";
      gcb = "git checkout -b";
      gcm = "git checkout main";
      gco = "git checkout";
      gd = "git diff";
      gl = "git pull";
      gp = "git push";
      gst = "git status";
    };

    initExtra = ''
      bindkey -v

      # Allows me to press escape to edit the command line in $EDITOR.
      autoload -z edit-command-line
      zle -N edit-command-line
      bindkey '^X^E' edit-command-line
      bindkey -M vicmd v edit-command-line

      # Custom vi-style movement: i/k/j/l for up/down/left/right.
      bindkey -M vicmd i up-line-or-history
      bindkey -M vicmd k down-line-or-history
      bindkey -M vicmd j backward-char
      bindkey -M vicmd l forward-char

      TMOUT=1
      TRAPALRM() {
        zle reset-prompt
      }

      if [ -f ~/.env ]; then
        . ~/.env
      fi
    '';
  };
}
