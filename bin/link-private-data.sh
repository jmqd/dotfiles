#!/usr/bin/env bash
set -euo pipefail

private_cloud_root="${PRIVATE_CLOUD_ROOT:-$HOME/cloud/mcqueen.jordan}"
private_s3_bucket="${PRIVATE_S3_BUCKET:-s3://mcqueen.jordan}"
sync_private_data=1

usage() {
  cat <<EOF
usage: $(basename "$0") [--no-sync]

Sync private dotfile data from cloud storage and link the local private files that
remain outside Home Manager for now.

Environment overrides:
  PRIVATE_CLOUD_ROOT   default: $private_cloud_root
  PRIVATE_S3_BUCKET    default: $private_s3_bucket
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_link() {
  local source="$1"
  local destination="$2"

  [ -e "$source" ] || die "missing source: $source"

  if [ -L "$destination" ]; then
    local current_target
    current_target="$(readlink "$destination")"
    if [ "$current_target" = "$source" ]; then
      echo "ok: $destination"
      return
    fi
    die "destination already links elsewhere: $destination -> $current_target"
  fi

  if [ -e "$destination" ]; then
    die "destination already exists and is not a symlink: $destination"
  fi

  ln -s "$source" "$destination"
  echo "linked: $destination -> $source"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-sync)
      sync_private_data=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

mkdir -p "$HOME/cloud" "$private_cloud_root" "$HOME/.aws"

if [ "$sync_private_data" -eq 1 ]; then
  require_command aws
  echo "Syncing private data from $private_s3_bucket ..."
  aws s3 sync "$private_s3_bucket" "$private_cloud_root/"
fi

echo "Linking private data files ..."
ensure_link "$private_cloud_root/secrets/dotfiles/.password-store" "$HOME/.password-store"
ensure_link "$private_cloud_root/secrets/dotfiles/.gpg-id" "$HOME/.gpg-id"
ensure_link "$private_cloud_root/dotfiles/.env" "$HOME/.env"
ensure_link "$private_cloud_root/secrets/dotfiles/.git-credentials" "$HOME/.git-credentials"
ensure_link "$private_cloud_root/dotfiles/.cloudhome.json" "$HOME/.cloudhome.json"

echo
echo "Done. Home Manager handles public dotfiles; this script only links private data."
