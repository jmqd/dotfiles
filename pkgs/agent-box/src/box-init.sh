#!/bin/sh
# Runs inside an agent-box container. Points git, gh, curl, Node and Nix at
# the session proxy and its CA, clones the target repo into /work/repo on the
# first run, then starts an interactive shell there.
#
# Reads (set by `agent-box run`):
#   AGENT_BOX_STORE_PATHS  colon-separated store paths of the session packages
#   AGENT_BOX_PROXY        proxy URL, including its login
#   AGENT_BOX_REPO         OWNER/NAME
#   AGENT_BOX_BRANCH       branch to check out (optional)
#   AGENT_BOX_PR           fork PR number to check out (optional)
#   AGENT_BOX_GRANT        one-line description of what the session may write
#   AGENT_BOX_GIT_NAME, AGENT_BOX_GIT_EMAIL  commit identity (optional)
# Writes only under /work.
set -u

say() { printf 'agent-box: %s\n' "$1" >&2; }
err() {
	say "error: $1"
	exit 1
}
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }

system_ca=""

setup_path() {
	session_path=""
	old_ifs=$IFS
	IFS=:
	for store_path in $AGENT_BOX_STORE_PATHS; do
		if [ -d "$store_path/bin" ]; then
			session_path="${session_path:+$session_path:}$store_path/bin"
		fi
		if [ -f "$store_path/etc/ssl/certs/ca-bundle.crt" ]; then
			system_ca="$store_path/etc/ssl/certs/ca-bundle.crt"
		fi
	done
	IFS=$old_ifs
	export PATH="$session_path:$PATH"
}

# Every TLS client trusts the public roots plus this session's CA, which the
# proxy uses for github.com and api.github.com.
setup_tls() {
	[ -n "$system_ca" ] || err "no CA bundle among the session packages"
	bundle="$HOME/.agent-box-ca.pem"
	ensure mkdir -p "$HOME"
	cat "$system_ca" /run/agent-box/ca.pem >"$bundle" || err "could not write $bundle"
	export SSL_CERT_FILE="$bundle" NIX_SSL_CERT_FILE="$bundle" GIT_SSL_CAINFO="$bundle"
	export CURL_CA_BUNDLE="$bundle" REQUESTS_CA_BUNDLE="$bundle"
	export NODE_EXTRA_CA_CERTS=/run/agent-box/ca.pem
}

# The container holds no GitHub credential. The proxy adds the real token;
# gh only needs a placeholder to send requests at all.
setup_proxy() {
	export HTTPS_PROXY="$AGENT_BOX_PROXY" https_proxy="$AGENT_BOX_PROXY"
	export NODE_USE_ENV_PROXY=1
	export GH_TOKEN=injected-by-agent-box-proxy
}

# Git config through the environment applies to every git process and leaves
# no file for the repo's code to rewrite.
setup_git() {
	set -- \
		url.https://github.com/.insteadOf git@github.com: \
		url.https://github.com/.insteadOf ssh://git@github.com/ \
		safe.directory '*'
	if [ -n "${AGENT_BOX_GIT_NAME:-}" ]; then
		set -- "$@" user.name "$AGENT_BOX_GIT_NAME"
	fi
	if [ -n "${AGENT_BOX_GIT_EMAIL:-}" ]; then
		set -- "$@" user.email "$AGENT_BOX_GIT_EMAIL"
	fi
	count=0
	while [ "$#" -ge 2 ]; do
		export "GIT_CONFIG_KEY_$count=$1" "GIT_CONFIG_VALUE_$count=$2"
		count=$((count + 1))
		shift 2
	done
	export GIT_CONFIG_COUNT="$count"
}

clone_repo() {
	if [ -d /work/repo/.git ]; then
		return 0
	fi
	url="https://github.com/$AGENT_BOX_REPO.git"
	branch="${AGENT_BOX_BRANCH:-}"
	pr="${AGENT_BOX_PR:-}"
	if [ -n "$branch" ]; then
		if git ls-remote --exit-code --heads "$url" "$branch" >/dev/null; then
			ensure git clone --branch "$branch" "$url" /work/repo
		else
			say "branch $branch does not exist yet; creating it from the default branch"
			ensure git clone "$url" /work/repo
			ensure git -C /work/repo switch --create "$branch"
		fi
	elif [ -n "$pr" ]; then
		ensure git clone "$url" /work/repo
		ensure git -C /work/repo fetch origin "pull/$pr/head:pr-$pr"
		ensure git -C /work/repo switch "pr-$pr"
	else
		ensure git clone "$url" /work/repo
	fi
}

main() {
	setup_path
	need_cmd git
	need_cmd bash
	setup_tls
	setup_proxy
	setup_git
	clone_repo
	cd /work/repo || err "cannot enter /work/repo"
	say "$AGENT_BOX_GRANT"
	if [ "$#" -gt 0 ]; then
		exec "$@"
	fi
	exec bash
}

main "$@" || exit 1
