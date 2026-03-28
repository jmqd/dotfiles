{ config, lib, pkgs, ... }:
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
    bottom
    broot
    cloc
    cmake
    difftastic
    fd
    git
    git-lfs
    gnuplot
    graphviz
    jq
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
