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
    fileSystems = [ "/srv/nas" ];
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

  # Never serve an empty directory from the system disk if the NAS is absent.
  systemd.services.nfs-server = {
    requires = [
      "srv-nas.mount"
      "srv-nas-frigate.mount"
    ];
    after = [
      "srv-nas.mount"
      "srv-nas-frigate.mount"
    ];
    bindsTo = [
      "srv-nas.mount"
      "srv-nas-frigate.mount"
    ];
  };
}
