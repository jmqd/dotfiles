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

  # The NFSv4 root (fsid=0) is an empty tmpfs that only holds the subvolume
  # mount points. If it were the btrfs top level, its backups/media/frigate
  # directories would be those subvolumes: a client denied a subvolume's
  # export would read the same data through the read-only root instead.
  fileSystems."/srv/nas" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "mode=0755"
      "size=1M"
    ];
  };

  # The btrfs top level stays outside the exported tree, for scrubs and
  # subvolume administration.
  fileSystems."/mnt/nas-top" = {
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

  # A separate filesystem boundary gives this NFS export its own write policy
  # rather than inheriting the read-only fsid=0 parent.
  fileSystems."/srv/nas/frigate" = {
    device = nasDevice;
    fsType = "btrfs";
    options = btrfsOptions ++ [ "subvol=frigate" ];
  };

  systemd.tmpfiles.rules = [
    "d /srv/nas/shared 2775 jmq nas - -"
    "d /srv/nas/backups 2770 jmq nas - -"
    "d /srv/nas/media 2775 jmq nas - -"
    "d /srv/nas/frigate 2770 jmq nas - -"
  ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/mnt/nas-top" ];
  };

  services.smartd = {
    enable = true;
    devices = [ { device = nasDisk; } ];
  };

  # glass (homelab repo, hosts/glass) keeps its media, Frigate recordings and
  # backups here, so those shares accept only glass's tailnet address: NFS
  # trusts the client's claimed uid, and any other tailnet device (tagged
  # family devices included) could otherwise write as anyone. Frigate writes
  # as root, so its share maps every write to jmq:nas (all_squash). Acknowledge
  # writes only once committed, so an NAS interruption cannot lose accepted data.
  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas         100.64.0.0/10(ro,fsid=0,no_subtree_check,crossmnt)
      /srv/nas/shared  100.64.0.0/10(rw,sync,no_subtree_check)
      /srv/nas/backups 100.97.225.21(rw,sync,no_subtree_check)
      /srv/nas/media   100.97.225.21(rw,sync,no_subtree_check)
      /srv/nas/frigate 100.97.225.21(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=2000)
    '';
  };

  # Never serve an empty directory from the system disk if the NAS is absent:
  # every exported subvolume must be mounted.
  systemd.services.nfs-server =
    let
      nasMounts = [
        "srv-nas.mount"
        "srv-nas-shared.mount"
        "srv-nas-backups.mount"
        "srv-nas-media.mount"
        "srv-nas-frigate.mount"
      ];
    in
    {
      requires = nasMounts;
      after = nasMounts;
      bindsTo = nasMounts;
    };
}
