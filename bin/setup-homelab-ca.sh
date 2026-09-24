#!/usr/bin/env bash
# Trust the homelab CA (pki/homelab-ca.crt) system-wide so browsers and CLI
# tools accept https://*.internal. The CA's name constraints limit it to
# .internal names, 192.168.1.0/24 and tailnet addresses.
#
# Safe to rerun: it checks first and uses sudo only when a change is needed.
# NixOS hosts trust the CA through security.pki.certificateFiles instead.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ca_file="$repo_root/pki/homelab-ca.crt"
os_name="$(uname -s)"
readonly repo_root ca_file os_name

as_root() {
	if [[ "$(id -u)" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

setup_macos() {
	# verify-cert succeeds only when the certificate chains to a trusted root.
	if security verify-cert -c "$ca_file" -p basic -L -l -q >/dev/null 2>&1; then
		echo "Homelab CA is already trusted."
		return
	fi

	echo "Adding the homelab CA to the System keychain (macOS may ask to confirm)..."
	as_root security add-trusted-cert -d -r trustRoot \
		-k /Library/Keychains/System.keychain "$ca_file"

	if ! security verify-cert -c "$ca_file" -p basic -L -l -q >/dev/null 2>&1; then
		echo "The homelab CA was added but macOS does not trust it." >&2
		exit 1
	fi
	echo "Homelab CA trusted."
}

setup_linux() {
	local anchor refresh
	if [[ -r /etc/os-release ]] && grep -Eq '^ID=("?)nixos\1$' /etc/os-release; then
		echo "NixOS trusts the homelab CA through security.pki.certificateFiles; nothing to do."
		return
	fi

	if command -v update-ca-certificates >/dev/null 2>&1 && [[ -d /usr/local/share/ca-certificates ]]; then
		anchor=/usr/local/share/ca-certificates/homelab-ca.crt
		refresh=(update-ca-certificates)
	elif command -v update-ca-trust >/dev/null 2>&1 && [[ -d /etc/pki/ca-trust/source/anchors ]]; then
		anchor=/etc/pki/ca-trust/source/anchors/homelab-ca.crt
		refresh=(update-ca-trust extract)
	elif command -v update-ca-trust >/dev/null 2>&1 && [[ -d /etc/ca-certificates/trust-source/anchors ]]; then
		anchor=/etc/ca-certificates/trust-source/anchors/homelab-ca.crt
		refresh=(update-ca-trust extract)
	else
		echo "No supported system trust store found (update-ca-certificates or update-ca-trust); no files changed." >&2
		exit 1
	fi

	# Compare in bash: minimal images lack cmp (diffutils).
	if [[ -r "$anchor" && "$(<"$anchor")" == "$(<"$ca_file")" ]]; then
		echo "Homelab CA is already trusted."
		return
	fi

	echo "Installing the homelab CA as $anchor..."
	as_root install -m 0644 "$ca_file" "$anchor"
	as_root "${refresh[@]}"
	echo "Homelab CA trusted."
}

case "$os_name" in
Darwin) setup_macos ;;
Linux) setup_linux ;;
*)
	echo "Unsupported OS: $os_name" >&2
	exit 1
	;;
esac
