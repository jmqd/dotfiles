#!/usr/bin/env bash
# Stop trusting the Nix community binary cache on a Mac that an earlier
# version of this repo configured. Only cache.nixos.org and the installer's
# defaults remain as binary sources afterwards.
#
# Safe to rerun: it changes nothing when the cache is already gone. Run it
# with sudo; it edits /etc/nix and restarts the Nix daemon.
set -euo pipefail

config_dir="${NIX_CONF_DIR:-/etc/nix}"
cache_config="$config_dir/dotfiles-cache.conf"
custom_config="$config_dir/nix.custom.conf"
readonly config_dir cache_config custom_config

changed=0

if grep -Fxq 'include dotfiles-cache.conf' "$custom_config" 2>/dev/null; then
	tmp_config="$(mktemp "$config_dir/.nix-custom.XXXXXX")"
	trap 'rm -f "$tmp_config"' EXIT
	# grep exits 1 when no other line remains; an empty file is correct then.
	grep -Fxv 'include dotfiles-cache.conf' "$custom_config" >"$tmp_config" || [[ $? -eq 1 ]]
	chmod 0644 "$tmp_config"
	mv -f "$tmp_config" "$custom_config"
	changed=1
fi

# Keep the old file under another name: nothing includes it, and it shows
# what was trusted before.
if [[ -e "$cache_config" ]]; then
	mv -f "$cache_config" "$cache_config.removed"
	changed=1
fi

if [[ "$changed" -eq 0 ]]; then
	echo "The Nix community binary cache is not configured; nothing to do."
	exit 0
fi

# Alternate configuration directories are useful for offline provisioning;
# they do not configure the running machine's daemon.
if [[ "$config_dir" == /etc/nix ]]; then
	if /bin/launchctl print system/systems.determinate.nix-daemon >/dev/null 2>&1; then
		/bin/launchctl kickstart -k system/systems.determinate.nix-daemon
	else
		/bin/launchctl kickstart -k system/org.nixos.nix-daemon
	fi
fi

echo "Removed the Nix community binary cache from $config_dir."
