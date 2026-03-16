{ ... }:
{
  home.file = {
    ".bashrc".source = ../.bashrc;
    ".gdbinit".source = ../.gdbinit;
    ".sqliterc".source = ../.sqliterc;
  };
}
