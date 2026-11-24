{
  lib,
  pkgs,
  ...
}:
let
  tomlFormat = pkgs.formats.toml { };
  sccacheBin = lib.getExe pkgs.sccache;
  linuxTarget = {
    linker = "${pkgs.clang}/bin/clang";
    rustflags = [
      "-C"
      "link-arg=-fuse-ld=${lib.getExe pkgs.mold}"
    ];
  };
in
{
  home.packages =
    (with pkgs; [
      cargo-binstall
      cargo-cache
      cargo-nextest
      sccache
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (
      with pkgs;
      [
        clang
        mold
      ]
    );

  # Share compiled dependency artifacts across worktrees and checkouts via
  # sccache without forcing CARGO_INCREMENTAL=0 globally, so local leaf crates
  # keep incremental builds. Darwin keeps Apple's ld-prime (mold is ELF-only).
  home.file.".cargo/config.toml".source = tomlFormat.generate "cargo-config.toml" (
    {
      build = {
        rustc-wrapper = sccacheBin;
      };
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      target = {
        "x86_64-unknown-linux-gnu" = linuxTarget;
        "aarch64-unknown-linux-gnu" = linuxTarget;
      };
    }
  );

  home.sessionVariables = {
    SCCACHE_CACHE_SIZE = "20G";
    CMAKE_C_COMPILER_LAUNCHER = sccacheBin;
    CMAKE_CXX_COMPILER_LAUNCHER = sccacheBin;
  };
}
