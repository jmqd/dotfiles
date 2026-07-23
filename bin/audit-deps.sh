#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

failures=0
updates=0
residuals=0
tmp_paths=()

cleanup() {
	for path in "${tmp_paths[@]}"; do
		rm -rf "$path"
	done
}
trap cleanup EXIT

section() {
	printf '\n==> %s\n' "$*"
}

ok() {
	printf 'ok: %s\n' "$*"
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

fail() {
	printf 'error: %s\n' "$*" >&2
	failures=$((failures + 1))
}

require_tool() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "missing required tool: $1"
		return 1
	fi
}

run_required() {
	if "$@"; then
		ok "$*"
	else
		fail "command failed: $*"
	fi
}

flake_expr() {
	nix eval --impure --raw --expr "let flake = builtins.getFlake (toString ${repo_root}); in $*"
}

package_version() {
	local system="$1" attr="$2"
	flake_expr "flake.packages.\"${system}\".\"${attr}\".version"
}

input_path() {
	local input="$1"
	flake_expr "flake.inputs.\"${input}\".outPath"
}

note_upgrade() {
	local name="$1" current="$2" latest="$3"
	if [ "$current" = "$latest" ]; then
		ok "$name is current at $current"
	else
		updates=$((updates + 1))
		printf 'upgrade available: %s %s -> %s\n' "$name" "$current" "$latest"
	fi
}

npm_latest_version() {
	local package="$1"
	nix shell --quiet nixpkgs#nodejs -c npm view "$package" version
}

check_npm_latest() {
	local name="$1" package="$2" current="$3" latest
	section "latest check: $name"
	if latest="$(npm_latest_version "$package")"; then
		note_upgrade "$name" "$current" "$latest"
	else
		fail "could not fetch latest npm version for $package"
	fi
}

github_api_headers() {
	local args=(
		--header "Accept: application/vnd.github+json"
		--header "User-Agent: dotfiles-audit-deps"
	)
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
	fi
	printf '%s\n' "${args[@]}"
}

github_release_latest_api() {
	local repo="$1"
	local -a headers=()
	while IFS= read -r header; do
		headers+=("$header")
	done < <(github_api_headers)
	curl --fail --silent --show-error --location "${headers[@]}" "https://api.github.com/repos/${repo}/releases/latest" |
		jq -er '.tag_name // empty'
}

github_release_latest_web() {
	local repo="$1" latest_url latest_tag
	latest_url="$(curl --fail --silent --show-error --location --write-out '%{url_effective}' --output /dev/null "https://github.com/${repo}/releases/latest")"
	latest_tag="${latest_url##*/}"
	[ -n "$latest_tag" ] && [ "$latest_tag" != "latest" ] || return 1
	printf '%s\n' "$latest_tag"
}

check_github_release_latest() {
	local repo="$1" current_tag="$2" latest_tag
	section "latest check: $repo"
	if latest_tag="$(github_release_latest_api "$repo" 2>/dev/null)" || latest_tag="$(github_release_latest_web "$repo")"; then
		note_upgrade "$repo" "$current_tag" "$latest_tag"
	else
		fail "could not fetch latest GitHub release for $repo"
	fi
}
check_codex_desktop_latest() {
	local current="$1" feed_arm feed_x64 latest_arm latest_x64
	section "latest check: codex-desktop"

	if ! feed_arm="$(curl --fail --silent --show-error --location \
		"https://persistent.oaistatic.com/codex-app-prod/appcast.xml")"; then
		fail "could not fetch Codex Desktop arm64 appcast"
		return
	fi
	if ! feed_x64="$(curl --fail --silent --show-error --location \
		"https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml")"; then
		fail "could not fetch Codex Desktop x86_64 appcast"
		return
	fi

	local version_pattern='<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>'
	local release_version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
	if [[ "$feed_arm" =~ $version_pattern ]]; then
		latest_arm="${BASH_REMATCH[1]}"
	else
		fail "Codex Desktop arm64 appcast is missing a short version"
		return
	fi
	if [[ ! "$latest_arm" =~ $release_version_pattern ]]; then
		fail "Codex Desktop arm64 appcast has malformed version: $latest_arm"
		return
	fi
	if [[ "$feed_x64" =~ $version_pattern ]]; then
		latest_x64="${BASH_REMATCH[1]}"
	else
		fail "Codex Desktop x86_64 appcast is missing a short version"
		return
	fi
	if [[ ! "$latest_x64" =~ $release_version_pattern ]]; then
		fail "Codex Desktop x86_64 appcast has malformed version: $latest_x64"
		return
	fi

	if [ "$latest_arm" != "$latest_x64" ]; then
		fail "Codex Desktop appcast versions differ: arm64 $latest_arm, x86_64 $latest_x64"
		return
	fi

	note_upgrade "codex-desktop" "$current" "$latest_arm"
}

npm_audit() {
	local name="$1" prefix="$2"
	section "npm audit: $name"
	run_required nix shell --quiet nixpkgs#nodejs -c npm audit --prefix "$prefix" --omit dev
}

cargo_audit_lock() {
	local name="$1" lock_file="$2"
	shift 2

	section "cargo audit: $name"

	local args=(audit --file "$lock_file")
	if [ "$#" -gt 0 ]; then
		printf 'known residual upstream advisories ignored for pass/fail: %s\n' "$*"
		residuals=$((residuals + $#))
		for advisory in "$@"; do
			args+=(--ignore "$advisory")
		done
	fi

	local output_file status
	output_file="$(mktemp)"
	tmp_paths+=("$output_file")

	set +e
	nix run nixpkgs#cargo-audit -- "${args[@]}" >"$output_file" 2>&1
	status=$?
	set -e

	if [ "$status" -eq 0 ]; then
		ok "cargo audit passed for $name"
	else
		cat "$output_file"
		fail "cargo audit failed for $name"
	fi
}

sorted_ids_file() {
	local output="$1" file="$2"
	grep -Eo 'GO-[0-9]{4}-[0-9]+' "$output" | sort -u >"$file" || true
}

check_known_go_vulns() {
	local name="$1" output_file="$2"
	shift 2

	local found_ids known_ids unknown_ids
	found_ids="$(mktemp)"
	known_ids="$(mktemp)"
	unknown_ids="$(mktemp)"
	tmp_paths+=("$found_ids" "$known_ids" "$unknown_ids")

	sorted_ids_file "$output_file" "$found_ids"
	printf '%s\n' "$@" | sort -u >"$known_ids"
	comm -23 "$found_ids" "$known_ids" >"$unknown_ids"

	if [ ! -s "$found_ids" ]; then
		cat "$output_file"
		fail "$name failed without reporting Go vulnerability IDs"
		return
	fi

	if [ -s "$unknown_ids" ]; then
		cat "$output_file"
		fail "$name reported new Go vulnerability IDs: $(tr '\n' ' ' <"$unknown_ids")"
		return
	fi

	local count
	count="$(wc -l <"$found_ids" | tr -d ' ')"
	residuals=$((residuals + count))
	ok "$name only reported known residual Go advisories: $(tr '\n' ' ' <"$found_ids")"
}

govulncheck_notion_cli() {
	local notion_src="$1"
	section "govulncheck: lox/notion-cli"

	local work_dir output_file status
	work_dir="$(mktemp -d)"
	output_file="$(mktemp)"
	tmp_paths+=("$work_dir" "$output_file")
	local go_mod_cache go_build_cache
	go_mod_cache="$(mktemp -d)"
	go_build_cache="$(mktemp -d)"
	tmp_paths+=("$go_mod_cache" "$go_build_cache")

	cp -R "$notion_src"/. "$work_dir"/
	chmod -R u+w "$work_dir"

	set +e
	(
		cd "$work_dir"
		env \
			GOMODCACHE="${GOMODCACHE:-$go_mod_cache}" \
			GOCACHE="${GOCACHE:-$go_build_cache}" \
			GOFLAGS="${GOFLAGS:-} -modcacherw" \
			nix shell nixpkgs#govulncheck nixpkgs#go -c govulncheck -scan=module
	) >"$output_file" 2>&1
	status=$?
	set -e

	if [ "$status" -eq 0 ]; then
		ok "lox/notion-cli govulncheck is clean"
	else
		check_known_go_vulns \
			"lox/notion-cli govulncheck" \
			"$output_file" \
			GO-2026-4514 \
			GO-2026-4918 \
			GO-2026-4970 \
			GO-2026-5024 \
			GO-2026-5025 \
			GO-2026-5026 \
			GO-2026-5027 \
			GO-2026-5028 \
			GO-2026-5029 \
			GO-2026-5030 \
			GO-2026-5037 \
			GO-2026-5038 \
			GO-2026-5039 \
			GO-2026-5320 \
			GO-2026-5856
	fi
}

main() {
	section "tooling"
	require_tool curl
	require_tool git
	require_tool jq
	require_tool nix

	if [ "$failures" -gt 0 ]; then
		exit 1
	fi

	local system
	system="$(nix eval --impure --raw --expr builtins.currentSystem)"
	ok "current system is $system"

	local pi_version oracle_version claude_version codex_version notion_version gws_version
	pi_version="$(package_version "$system" pi)"
	oracle_version="$(package_version "$system" oracle)"
	claude_version="$(package_version "$system" claude-code)"
	codex_version="$(package_version "$system" codex)"
	notion_version="$(package_version "$system" notion-cli)"
	gws_version="$(package_version "$system" googleworkspace-cli)"

	check_github_release_latest "can1357/oh-my-pi" "v${pi_version}"
	check_npm_latest "oracle" "@steipete/oracle" "$oracle_version"
	check_npm_latest "claude-code" "@anthropic-ai/claude-code" "$claude_version"
	check_github_release_latest "openai/codex" "rust-v${codex_version}"
	check_github_release_latest "googleworkspace/cli" "v${gws_version}"
	check_github_release_latest "lox/notion-cli" "v${notion_version}"

	warn "codex-desktop uses versioned OpenAI ZIP URLs; latest-version checks are not automated here"

	npm_audit "pi" "pkgs/pi"
	npm_audit "oracle" "pkgs/oracle"

	local codex_src gws_src trueflow_src notion_src voxtype_src
	codex_src="$(input_path codex)"
	gws_src="$(input_path googleworkspace-cli)"
	trueflow_src="$(input_path trueflow)"
	notion_src="$(input_path notion-cli)"
	voxtype_src="$(input_path voxtype)"

	cargo_audit_lock "pkgs/flow" "pkgs/flow/Cargo.lock"
	cargo_audit_lock \
		"googleworkspace/cli" \
		"$gws_src/Cargo.lock" \
		RUSTSEC-2026-0185 \
		RUSTSEC-2026-0104 \
		RUSTSEC-2026-0098 \
		RUSTSEC-2026-0099
	cargo_audit_lock \
		"trueflow" \
		"$trueflow_src/trueflow/Cargo.lock"
	cargo_audit_lock \
		"voxtype" \
		"$voxtype_src/Cargo.lock" \
		RUSTSEC-2026-0007 \
		RUSTSEC-2026-0185 \
		RUSTSEC-2026-0049 \
		RUSTSEC-2026-0104 \
		RUSTSEC-2026-0098 \
		RUSTSEC-2026-0099 \
		RUSTSEC-2026-0194 \
		RUSTSEC-2026-0195 \
		RUSTSEC-2026-0204
	cargo_audit_lock \
		"openai/codex codex-rs" \
		"$codex_src/codex-rs/Cargo.lock" \
		RUSTSEC-2026-0118 \
		RUSTSEC-2026-0119 \
		RUSTSEC-2026-0185 \
		RUSTSEC-2026-0194 \
		RUSTSEC-2026-0195
	cargo_audit_lock \
		"openai/codex argument-comment-lint" \
		"$codex_src/tools/argument-comment-lint/Cargo.lock" \
		RUSTSEC-2026-0067 \
		RUSTSEC-2026-0068

	govulncheck_notion_cli "$notion_src"

	section "summary"
	printf 'updates available: %s\n' "$updates"
	printf 'known residual advisories: %s\n' "$residuals"
	printf 'unexpected failures: %s\n' "$failures"

	if [ "$failures" -gt 0 ]; then
		exit 1
	fi
}

main "$@"
