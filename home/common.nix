{ config, lib, pkgs, ... }:
let
  # Keep expensive local-build packages out of the baseline switch path.
  # Flip these to true on machines that explicitly want them.
  enableMise = false;
  enableTexliveOrgPdf = false;

  berkleyMono = pkgs.callPackage ../pkgs/berkley-mono { };
  texliveOrgPdf = pkgs.texlive.combine {
    # Enough for normal Org LaTeX/PDF export, latexmk workflows, and CJK
    # documents via LuaLaTeX/XeLaTeX without pulling in scheme-full's multi-GB
    # closure.
    inherit (pkgs.texlive)
      scheme-small
      latexmk
      collection-luatex
      collection-xetex
      collection-langcjk
      fontspec
      unicode-math
      xecjk
      ctex
      luatexja
      ;
  };
  aspellWithDicts = pkgs.aspellWithDicts (dicts: [
    dicts.en
    dicts."en-computers"
  ]);
  misePackage =
    if pkgs.stdenv.hostPlatform.isDarwin then
      (pkgs.mise.override {
        # Keep mise from pulling in a second, default direnv build whose tests
        # can hang on Darwin. Reuse the Home Manager direnv package instead.
        direnv = config.programs.direnv.package;
      }).overrideAttrs
        (_old: {
          # Avoid a long Rust test phase for this locally rebuilt package.
          doCheck = false;
        })
    else
      pkgs.mise;
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

  # Home Manager's generated option manpage currently triggers a Nix string-context
  # warning via nixosOptionsDoc. Disable only that generated HM manpage; package
  # manpages remain available.
  manual.manpages.enable = false;

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
      tree-sitter
      typescript-language-server
      unzip
      wget
      zig
      zip
      zls
      zola
    ])
    ++ lib.optionals enableMise [ misePackage ]
    ++ lib.optionals enableTexliveOrgPdf [ texliveOrgPdf ]
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
