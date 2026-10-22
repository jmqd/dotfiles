{ lib, pkgs, ... }:
let
  # fd respects .gitignore, so pickers skip build output and vendored trees.
  # No --follow: from $HOME it would chase profile links into /nix/store.
  fdBase = "${lib.getExe pkgs.fd} --hidden --exclude .git";
in
{
  # Ctrl-R history, Ctrl-T file, and Alt-C directory pickers. The bindings are
  # installed in the emacs, viins, and vicmd keymaps, so they survive bindkey -v.
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    defaultCommand = "${fdBase} --type f";
    defaultOptions = [
      "--height=40%"
      "--layout=reverse"
      "--border"
    ];
    fileWidget = {
      command = "${fdBase} --type f";
      options = [ "--preview 'head -n 200 {}'" ];
    };
    changeDirWidget = {
      command = "${fdBase} --type d";
      options = [ "--preview 'ls -A {}'" ];
    };
  };

  # `z foo` jumps to the most frecent directory matching foo; `zi` picks one
  # with fzf.
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history.extended = true;

    sessionVariables = {
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

    initContent = ''
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
        (( ''${+_fzf_picker_open} )) || zle reset-prompt
      }

      # Redrawing the prompt while an fzf picker owns the terminal kills the
      # picker within a second. The widgets run with a local flag that
      # TRAPALRM sees through zsh's dynamic scoping.
      for widget in fzf-file-widget fzf-cd-widget fzf-history-widget; do
        functions[_unguarded_$widget]=$functions[$widget]
        functions[$widget]="local _fzf_picker_open=1; _unguarded_$widget \"\$@\""
      done
      unset widget

      if [ -f ~/.env ]; then
        . ~/.env
      fi
    '';
  };
}
