{
  config,
  lib,
  pkgs,
  ...
}:

let
  nas = pkgs.writeShellApplication {
    name = "nas";
    runtimeInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux (
      with pkgs;
      [
        nfs-utils
        util-linux
      ]
    );
    text = ''
      set -euo pipefail

      host="''${NAS_HOST:-jmws}"
      root="''${NAS_MOUNT_ROOT:-$HOME/nas}"
      shares=(shared backups media)

      usage() {
        cat <<USAGE
      Usage: nas <mount|umount|status|path>

      Environment:
        NAS_HOST        NFS server name or Tailscale MagicDNS name. Default: jmws
        NAS_MOUNT_ROOT  Local mount root. Default: \$HOME/nas
      USAGE
      }

      is_mounted() {
        mount | grep -Eq "[[:space:]]$1[[:space:]]"
      }

      mount_share() {
        share="$1"
        target="$root/$share"
        mkdir -p "$target"

        if is_mounted "$target"; then
          echo "$target already mounted"
          return 0
        fi

        case "$(uname -s)" in
          Darwin)
            sudo /sbin/mount -t nfs -o vers=4,resvport "$host:/$share" "$target"
            ;;
          Linux)
            sudo mount -t nfs4 -o noatime,nosuid,nodev "$host:/$share" "$target"
            ;;
          *)
            echo "unsupported OS: $(uname -s)" >&2
            return 1
            ;;
        esac
      }

      umount_share() {
        share="$1"
        target="$root/$share"

        if ! is_mounted "$target"; then
          echo "$target not mounted"
          return 0
        fi

        case "$(uname -s)" in
          Darwin)
            sudo /sbin/umount "$target"
            ;;
          Linux)
            sudo umount "$target"
            ;;
          *)
            echo "unsupported OS: $(uname -s)" >&2
            return 1
            ;;
        esac
      }

      status_share() {
        share="$1"
        target="$root/$share"

        if is_mounted "$target"; then
          echo "$target mounted"
        else
          echo "$target not mounted"
        fi
      }

      cmd="''${1:-}"
      case "$cmd" in
        mount)
          for share in "''${shares[@]}"; do
            mount_share "$share"
          done
          ;;
        umount|unmount)
          for share in "''${shares[@]}"; do
            umount_share "$share"
          done
          ;;
        status)
          for share in "''${shares[@]}"; do
            status_share "$share"
          done
          ;;
        path)
          echo "$root"
          ;;
        -h|--help|help|"")
          usage
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  home.sessionVariables = {
    NAS_HOST = "jmws";
    NAS_MOUNT_ROOT = "${config.home.homeDirectory}/nas";
  };

  home.packages = [ nas ];

  home.shellAliases = {
    nas-mount = "nas mount";
    nas-umount = "nas umount";
    nas-status = "nas status";
  };
}
