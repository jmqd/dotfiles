{ config, lib, pkgs, ... }:
let
  berkleyMono = pkgs.callPackage ../pkgs/berkley-mono { };
  aspellWithDicts = pkgs.aspellWithDicts (dicts: [
    dicts.en
    dicts."en-computers"
  ]);
in
{
  imports = [
    ./direnv.nix
    ./emacs.nix
    ./files.nix
    ./gpg.nix
    ./git.nix
    ./ssh.nix
    ./tmux.nix
    ./wezterm.nix
    ./zsh.nix
  ];

  home.stateVersion = "25.05";
  programs.home-manager.enable = true;

  # Shared baseline tools available across platforms.
  home.packages =
    (with pkgs; [
      berkleyMono
      aspellWithDicts
      awscli2
      basedpyright
      bottom
      broot
      clang-tools
      cloc
      cmake
      difftastic
      fd
      flock
      gh
      git
      git-lfs
      gopls
      gnuplot
      graphviz
      imagemagick
      jq
      lefthook
      languagetool
      lldb
      postgresql
      mise
      nil
      pandoc
      p7zip
      pkg-config
      plantuml
      procs
      protobuf
      ripgrep
      rustup
      slackdump
      shellcheck
      shfmt
      sqlite
      tealdeer
      tree-sitter
      typescript-language-server
      unzip
      wget
      zig
      zip
      zls
      zola
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [
      gdb
    ]);

  home.sessionPath = [
    "${config.home.homeDirectory}/.cargo/bin"
  ];

  home.activation.bootstrapRust = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export HOME=${lib.escapeShellArg config.home.homeDirectory}
    export PATH=${lib.escapeShellArg "${config.home.profileDirectory}/bin"}:$PATH
    export RUSTUP_BIN=${lib.escapeShellArg "${pkgs.rustup}/bin/rustup"}
    ${../bin/bootstrap-rust.sh} stable
  '';
}
