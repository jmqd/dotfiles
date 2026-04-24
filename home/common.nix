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
    ./flow-search.nix
    ./gpg.nix
    ./git.nix
    ./ssh.nix
    ./tmux.nix
    ./wezterm.nix
    ./zsh.nix
  ];

  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;

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
      just
      lefthook
      languagetool
      lldb
      postgresql
      mise
      nil
      noto-fonts-cjk-sans-static
      noto-fonts-cjk-serif-static
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
      texlive.combined.scheme-full
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

  home.sessionVariables = {
    LANG = "en_US.UTF-8";
    LC_CTYPE = "en_US.UTF-8";
    OSFONTDIR = lib.concatStringsSep ":" [
      "${config.home.profileDirectory}/share/fonts/opentype/noto-cjk"
      "${config.home.profileDirectory}/share/fonts/opentype/berkley-mono"
    ];
  };

  home.sessionPath = [
    "${config.home.homeDirectory}/.cargo/bin"
  ];

  home.activation.bootstrapRust = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export HOME=${lib.escapeShellArg config.home.homeDirectory}
    export PATH=${lib.escapeShellArg "${config.home.profileDirectory}/bin"}:$PATH
    export RUSTUP_BIN=${lib.escapeShellArg "${pkgs.rustup}/bin/rustup"}
    if ! ${../bin/bootstrap-rust.sh} stable; then
      if [ "''${HM_STRICT_RUST_BOOTSTRAP:-0}" = "1" ]; then
        echo "Rust bootstrap failed with HM_STRICT_RUST_BOOTSTRAP=1." >&2
        exit 1
      fi

      echo "warning: Rust bootstrap failed during Home Manager activation; continuing without a managed default toolchain." >&2
      echo "warning: Re-run bin/bootstrap-rust.sh stable after network access is available, or set HM_STRICT_RUST_BOOTSTRAP=1 to make this fatal again." >&2
    fi
  '';
}
