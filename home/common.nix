{ config, lib, pkgs, ... }:
let
  berkleyMono = pkgs.callPackage ../pkgs/berkley-mono { };
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
  home.packages = with pkgs; [
    berkleyMono
    basedpyright
    bottom
    broot
    clang-tools
    cloc
    cmake
    difftastic
    fd
    gh
    git
    git-lfs
    gopls
    gnuplot
    graphviz
    jq
    nil
    pandoc
    p7zip
    pkg-config
    plantuml
    procs
    protobuf
    ripgrep
    rustup
    sqlite
    tealdeer
    tree-sitter
    typescript-language-server
    wget
    zola
  ];

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
