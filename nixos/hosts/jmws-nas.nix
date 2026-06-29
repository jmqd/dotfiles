{ ... }:

let
  nasDevice = "/dev/disk/by-label/nas16";
  nasDisk = "/dev/disk/by-id/ata-ST16000DM001-3Y4103_ZXA077ZL";
  btrfsOptions = [
    "noatime"
    "compress=zstd:3"
    "nofail"
    "x-systemd.device-timeout=10s"
  ];
in
{
  users.groups.nas.gid = 2000;
  users.users.jmq.extraGroups = [ "nas" ];

  fileSystems."/srv/nas" = {
    device = nasDevice;
    fsType = "btrfs";
    options = btrfsOptions ++ [ "subvolid=5" ];
  };

  fileSystems."/srv/nas/shared" = {
    device = nasDevice;
    fsType = "btrfs";
    options = btrfsOptions ++ [ "subvol=shared" ];
  };

  fileSystems."/srv/nas/backups" = {
    device = nasDevice;
    fsType = "btrfs";
    options = btrfsOptions ++ [ "subvol=backups" ];
  };

  fileSystems."/srv/nas/media" = {
    device = nasDevice;
    fsType = "btrfs";
    options = btrfsOptions ++ [ "subvol=media" ];
  };

  systemd.tmpfiles.rules = [
    "d /srv/nas/shared 2775 jmq nas - -"
    "d /srv/nas/backups 2770 jmq nas - -"
    "d /srv/nas/media 2775 jmq nas - -"
  ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/srv/nas" ];
  };

  services.smartd = {
    enable = true;
    devices = [ { device = nasDisk; } ];
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas         100.64.0.0/10(ro,fsid=0,no_subtree_check,crossmnt)
      /srv/nas/shared  100.64.0.0/10(rw,sync,no_subtree_check)
      /srv/nas/backups 100.64.0.0/10(rw,sync,no_subtree_check)
      /srv/nas/media   100.64.0.0/10(rw,sync,no_subtree_check)
    '';
  };
}
