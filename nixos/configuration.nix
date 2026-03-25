{ ... }:
{
  imports = [
    <home-manager/nixos>
    ./hosts/jmws.nix
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.jmq = import ../home/hosts/jmq-linux.nix;
}
