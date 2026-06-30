{ config, ... }:
let
  homeDir = config.home.homeDirectory;
  jmwsHost = "jmws";
  jmwsUser = "jmq";
  jmwsTailnetIpv4 = "100.80.51.119";
  jmwsVncPort = "5900";
  nasRoot = "${homeDir}/nas";
in
{
  home.sessionVariables = {
    # Public identity.
    JM_NAME = "Jordan McQueen";
    JM_FULL_NAME = "Jordan McQueen";
    JM_EMAIL = "j@jm.dev";
    JM_DOMAIN = "jm.dev";
    JM_WEBSITE = "https://jm.dev";
    JM_GITHUB_USER = "jmqd";
    JM_GITHUB_PROFILE = "https://github.com/jmqd";

    # Public repo and local path conventions.
    JM_DOTFILES_REPO = "jmqd/dotfiles";
    JM_DOTFILES_DIR = "${homeDir}/src/dotfiles";
    JM_SRC_DIR = "${homeDir}/src";
    JM_CLOUD_DIR = "${homeDir}/cloud";

    # Homelab / tailnet handles. These are addresses, not credentials.
    JM_PRIMARY_HOST = jmwsHost;
    JM_HOMELAB_HOST = jmwsHost;
    JM_JMWS_HOST = jmwsHost;
    JM_JMWS_USER = jmwsUser;
    JM_JMWS_TAILSCALE_IP = jmwsTailnetIpv4;
    JM_JMWS_SSH = "${jmwsUser}@${jmwsHost}";
    JM_JMWS_SSH_TAILSCALE = "${jmwsUser}@${jmwsTailnetIpv4}";
    JM_JMWS_VNC_HOST = jmwsTailnetIpv4;
    JM_JMWS_VNC_PORT = jmwsVncPort;
    JM_JMWS_VNC_ADDR = "${jmwsTailnetIpv4}:${jmwsVncPort}";
    JM_JMWS_VNC_URL = "vnc://${jmwsTailnetIpv4}:${jmwsVncPort}";

    # NAS conventions; the nas helper also exposes NAS_HOST/NAS_MOUNT_ROOT.
    JM_NAS_HOST = jmwsHost;
    JM_NAS_MOUNT_ROOT = nasRoot;
    JM_NAS_SHARES = "shared backups media";
    JM_NAS_SHARED_DIR = "${nasRoot}/shared";
    JM_NAS_BACKUPS_DIR = "${nasRoot}/backups";
    JM_NAS_MEDIA_DIR = "${nasRoot}/media";
  };
}
