{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Jordan McQueen";
        email = "j@jm.dev";
      };

      alias = {
        graph = ''log --graph --full-history --all --color --pretty=tformat:"%x1b[31m%h%x09%x1b[32m%d%x1b[0m%x20%s%x20%x1b[33m(%an)%x1b[0m"'';
        fixup = ''!f() { [ "$#" -ge 1 ] || { echo "usage: git fixup <commit-ish> [commit args...]" >&2; return 1; }; target="$(git rev-parse "$1")" || return 1; shift; git commit --fixup="$target" "$@" && GIT_SEQUENCE_EDITOR=true git rebase -i --autostash --autosquash "$target^"; }; f'';
        dft = "-c diff.external=difft diff";
      };

      branch.sort = "-committerdate";
      commit.template = "~/.gitmessage";
      core = {
        commitGraph = true;
        editor = "${config.home.homeDirectory}/.local/bin/emacs-handcrafted-client";
        untrackedCache = true;
      };
      diff.algorithm = "histogram";
      feature.manyFiles = true;
      fetch = {
        parallel = 0;
        prune = true;
        writeCommitGraph = true;
      };
      gc.writeCommitGraph = true;
      index.threads = true;
      init.defaultBranch = "main";
      maintenance = {
        auto = true;
        strategy = "incremental";
      };
      merge.conflictStyle = "zdiff3";
      pack.threads = 0;
      pull.rebase = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      rerere.enabled = true;
      submodule.fetchJobs = 0;
      tag.sort = "-version:refname";
      url."git@github.com:".insteadOf = "https://github.com/";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      credential.helper = "osxkeychain";
    };

    # Scope the builtin fsmonitor daemon to ~/src/ so work repos speed up
    # without spawning daemons in /tmp tests or ~/nas NFS mounts.
    includes = [
      {
        condition = "gitdir:~/src/";
        contents = {
          core.fsmonitor = true;
        };
      }
    ];
  };

  home.file.".gitmessage".source = pkgs.replaceVars ../.gitmessage.in {
    writingStyle = import ./writing-style.nix;
  };

  # `git clean-stale`: report, and with --apply trash, worktrees with nothing left to keep.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "git-clean-stale";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gawk
        git
      ];
      text = builtins.readFile ../bin/git-clean-stale.sh;
    })
  ];
}
