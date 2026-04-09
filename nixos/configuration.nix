# Legacy compatibility stub for old `/etc/nixos/configuration.nix` symlinks.
builtins.throw ''
This repo no longer supports /etc/nixos/configuration.nix as the NixOS entrypoint.

Use the flake host instead:
  sudo nixos-rebuild switch --flake /path/to/dotfiles#jmws

Example:
  sudo nixos-rebuild switch --flake ~/src/dotfiles#jmws

If /etc/nixos/configuration.nix still points at this file, remove that symlink
or replace it with a local stub and use the flake command above.
''
