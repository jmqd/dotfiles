#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${NIX_CONF_DIR:-/etc/nix}"
cache_config="$config_dir/dotfiles-cache.conf"
custom_config="$config_dir/nix.custom.conf"

# Determinate owns nix.conf. Keep local settings in its supported include.
if ! grep -Eq '^[[:space:]]*!?include[[:space:]]+nix\.custom\.conf[[:space:]]*$' "$config_dir/nix.conf"; then
	echo "Expected $config_dir/nix.conf to include nix.custom.conf; no files changed." >&2
	exit 1
fi

changed=0
tmp_config="$(mktemp "$config_dir/.dotfiles-cache.XXXXXX")"
trap 'rm -f "$tmp_config"' EXIT
install -m 0644 "$repo_root/nix/cache.conf" "$tmp_config"
if ! cmp -s "$tmp_config" "$cache_config"; then
	mv -f "$tmp_config" "$cache_config"
	changed=1
fi

if ! grep -Fxq 'include dotfiles-cache.conf' "$custom_config" 2>/dev/null; then
	printf '\ninclude dotfiles-cache.conf\n' >>"$custom_config"
	changed=1
fi

if [[ "$changed" -eq 0 ]]; then
	echo "Nix binary cache configuration is already current."
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

echo "Configured the Nix community binary cache without granting trusted-user privileges."
