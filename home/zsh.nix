{
  config,
  lib,
  pkgs,
  ...
}:
let
  # fd respects .gitignore, so pickers skip build output and vendored trees.
  # No --follow: from $HOME it would chase profile links into /nix/store.
  fdBase = "${lib.getExe pkgs.fd} --hidden --exclude .git";

  # Pre-generate static shell hooks at build time so every interactive zsh
  # avoids spawning zoxide and direnv subprocesses just to emit fixed scripts.
  zoxideInitZsh = pkgs.runCommand "zoxide-init.zsh" { } ''
    ${lib.getExe pkgs.zoxide} init zsh > "$out"
  '';
  direnvHookZsh = pkgs.runCommand "direnv-hook.zsh" { } ''
    ${lib.getExe config.programs.direnv.package} hook zsh > "$out"
  '';
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
  # with fzf. Sourced from zoxideInitZsh below instead of runtime `eval`.
  programs.zoxide = {
    enable = true;
    enableZshIntegration = false;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    # /bin/zsh and the Nix zsh differ in version and fpath. Sharing one dump
    # makes each rebuild it (about 1 s) whenever the other ran last. Skip the
    # full fpath scan and compaudit when the dump is less than 24 hours old and
    # the active Nix profile has not changed. Touch the dump after `compinit -d`
    # because compinit skips rewriting when #files matches, which otherwise
    # leaves mtime >24h old and triggers compaudit on every future shell.
    completionInit = ''
      autoload -Uz compinit
      () {
        local dump="''${ZDOTDIR:-$HOME}/.zcompdump-$ZSH_VERSION"
        local stamp="$dump.profile"
        local profile=""
        if [[ -e "$HOME/.local/state/nix/profile" ]]; then
          profile="$HOME/.local/state/nix/profile"
        elif [[ -e "$HOME/.nix-profile" ]]; then
          profile="$HOME/.nix-profile"
        fi
        [[ -n "$profile" ]] && profile="''${profile:A}"
        local cached_profile=""
        [[ -r "$stamp" ]] && IFS= read -r cached_profile < "$stamp"
        if (( $# )) && [[ "$profile" == "$cached_profile" ]]; then
          compinit -C -d "$dump"
        else
          compinit -d "$dump"
          [[ -f "$dump" ]] && touch "$dump" 2>/dev/null || true
          printf '%s\n' "$profile" >| "$stamp" 2>/dev/null || true
          [[ -f "$dump" ]] && zcompile "$dump" 2>/dev/null || true
        fi
      } "''${ZDOTDIR:-$HOME}/.zcompdump-$ZSH_VERSION"(Nmh-24)
    '';

    profileExtra = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin ''
      # Determinate Nix hooks nix-daemon.sh in /etc/zshrc (interactive only),
      # so non-interactive login shells (e.g. Emacs exec-path-from-shell -l)
      # need Nix profiles added in ~/.zprofile.
      if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
      fi
      case ":$PATH:" in
        *":${config.home.profileDirectory}/bin:"*) ;;
        *) export PATH="${config.home.profileDirectory}/bin:/nix/var/nix/profiles/default/bin''${PATH:+:$PATH}" ;;
      esac
    '';

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history.extended = true;

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

      if [ -f ~/.env ]; then
        . ~/.env
      fi
    ''
    + lib.optionalString config.programs.direnv.enable ''
      source ${direnvHookZsh}
    ''
    + lib.optionalString config.programs.zoxide.enable ''
      source ${zoxideInitZsh}
    '';
  };
}
