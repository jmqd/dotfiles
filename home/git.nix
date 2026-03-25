{ ... }:
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
        fixup = ''!f() { [ "$#" -ge 1 ] || { echo "usage: git fixup <commit-ish> [commit args...]" >&2; return 1; }; target="$(git rev-parse "$1")" || return 1; shift; git commit --fixup="$target" "$@" && EDITOR=true git rebase -i --autostash --autosquash "$target^"; }; f'';
      };

      commit.template = "~/.gitmessage";
      core.editor = "emacsclient";
      init.defaultBranch = "main";
      pull.rebase = true;
      rebase.autoStash = true;
    };
  };

  home.file.".gitmessage".source = ../.gitmessage;
}
