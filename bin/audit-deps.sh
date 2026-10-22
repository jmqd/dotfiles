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
	DOTFILES_AUDIT_ROOT="$repo_root" nix eval --impure --raw --expr "let flake = builtins.getFlake (builtins.getEnv \"DOTFILES_AUDIT_ROOT\"); in $*"
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

# flow pin check owns the release feeds of every pin listed in pins/ and
# pkgs/flow/src/pins/registry.rs. It exits 1 when a pin failed but still
# prints the full report.
check_pins() {
	section "latest check: pins"
	local report name status pinned upstream detail
	report="$(nix run "$repo_root#flow" -- --output json pin check)" || true
	if ! jq -e '.command == "check"' <<<"$report" >/dev/null 2>&1; then
		fail "flow pin check produced no report"
		return
	fi
	while IFS=$'\t' read -r name status pinned upstream detail; do
		case "$status" in
		current | outdated) note_upgrade "$name" "$pinned" "$upstream" ;;
		manual_update)
			note_upgrade "$name" "$pinned" "$upstream"
			printf '  manual bump: %s\n' "$detail"
			;;
		failed) fail "flow pin check $name: $detail" ;;
		*) fail "flow pin check $name: unknown status $status" ;;
		esac
	done < <(jq -r '.data[] | [.name, .status, (.pinned // "?"), (.upstream // "?"), (.error // .reason // "")] | @tsv' <<<"$report")
}

# osv-scanner reads the lockfile directly, so no Node.js toolchain runs here.
osv_audit_lock() {
	local name="$1" lock_file="$2"
	shift 2
	local -a allowed_ids=("$@")
	section "osv-scanner: $name"

	local output_file stderr_file found_file allowed_file unexpected_file stale_file status
	output_file="$(mktemp)"
	stderr_file="$(mktemp)"
	found_file="$(mktemp)"
	allowed_file="$(mktemp)"
	unexpected_file="$(mktemp)"
	stale_file="$(mktemp)"
	tmp_paths+=("$output_file" "$stderr_file" "$found_file" "$allowed_file" "$unexpected_file" "$stale_file")

	set +e
	nix run --inputs-from "$repo_root" nixpkgs#osv-scanner -- scan --format json --lockfile "$lock_file" >"$output_file" 2>"$stderr_file"
	status=$?
	set -e

	# Exit 0 must report no findings and exit 1 must report some; anything
	# else, including empty or unparsable output, is an error.
	if ! jq -e '.results | type == "array"' "$output_file" >/dev/null 2>&1 ||
		! jq -r '[.results[]?.packages[]?.vulnerabilities[]?.id] | unique | .[]' "$output_file" >"$found_file" ||
		{ [ "$status" -eq 0 ] && [ -s "$found_file" ]; } ||
		{ [ "$status" -eq 1 ] && [ ! -s "$found_file" ]; } ||
		{ [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; }; then
		cat "$stderr_file" "$output_file"
		fail "osv-scanner failed for $name (exit $status)"
		return
	fi

	: >"$allowed_file"
	if [ "${#allowed_ids[@]}" -gt 0 ]; then
		printf '%s\n' "${allowed_ids[@]}" | sort -u >"$allowed_file"
	fi
	comm -23 "$found_file" "$allowed_file" >"$unexpected_file"
	comm -13 "$found_file" "$allowed_file" >"$stale_file"

	if [ -s "$unexpected_file" ] || [ -s "$stale_file" ]; then
		if [ -s "$unexpected_file" ]; then
			fail "$name reported unexpected advisories: $(tr '\n' ' ' <"$unexpected_file")"
		fi
		if [ -s "$stale_file" ]; then
			fail "$name advisory allowlist is stale: $(tr '\n' ' ' <"$stale_file")"
		fi
		return
	fi

	if [ ! -s "$found_file" ]; then
		ok "osv-scanner passed for $name"
		return
	fi

	local count
	count="$(wc -l <"$found_file" | tr -d ' ')"
	residuals=$((residuals + count))
	printf 'known residual advisories ignored for pass/fail: %s\n' "$(tr '\n' ' ' <"$found_file")"
	ok "osv-scanner passed for $name with documented residuals"
}

cargo_audit_lock() {
	local name="$1" lock_file="$2"
	shift 2

	section "cargo audit: $name"

	local -a allowed_ids=("$@")
	local json_file json_stderr actual_file allowed_file unexpected_file stale_file
	json_file="$(mktemp)"
	json_stderr="$(mktemp)"
	actual_file="$(mktemp)"
	allowed_file="$(mktemp)"
	unexpected_file="$(mktemp)"
	stale_file="$(mktemp)"
	tmp_paths+=("$json_file" "$json_stderr" "$actual_file" "$allowed_file" "$unexpected_file" "$stale_file")

	set +e
	nix run --inputs-from "$repo_root" nixpkgs#cargo-audit -- audit --file "$lock_file" --json >"$json_file" 2>"$json_stderr"
	set -e

	# Empty or error output must fail; jq alone accepts empty input.
	if ! jq -e '.vulnerabilities.list | type == "array"' "$json_file" >/dev/null 2>&1 ||
		! jq -r '[.vulnerabilities.list[].advisory.id] | sort | .[]' "$json_file" | sort -u >"$actual_file"; then
		cat "$json_stderr" "$json_file"
		fail "cargo audit JSON failed for $name"
		return
	fi

	: >"$allowed_file"
	if [ "${#allowed_ids[@]}" -gt 0 ]; then
		printf '%s\n' "${allowed_ids[@]}" | sort -u >"$allowed_file"
	fi
	comm -23 "$actual_file" "$allowed_file" >"$unexpected_file"
	comm -13 "$actual_file" "$allowed_file" >"$stale_file"

	if [ -s "$unexpected_file" ] || [ -s "$stale_file" ]; then
		cat "$json_stderr" "$json_file"
		if [ -s "$unexpected_file" ]; then
			fail "$name reported unexpected cargo advisories: $(tr '\n' ' ' <"$unexpected_file")"
		fi
		if [ -s "$stale_file" ]; then
			fail "$name cargo advisory allowlist is stale: $(tr '\n' ' ' <"$stale_file")"
		fi
		return
	fi

	local actual_count
	actual_count="$(wc -l <"$actual_file" | tr -d ' ')"
	if [ "$actual_count" -gt 0 ]; then
		residuals=$((residuals + actual_count))
		printf 'known residual upstream advisories ignored for pass/fail: %s\n' "$(tr '\n' ' ' <"$actual_file")"
	fi

	local args=(audit --file "$lock_file")
	for advisory in "${allowed_ids[@]}"; do
		args+=(--ignore "$advisory")
	done

	local output_file status
	output_file="$(mktemp)"
	tmp_paths+=("$output_file")

	set +e
	nix run --inputs-from "$repo_root" nixpkgs#cargo-audit -- "${args[@]}" >"$output_file" 2>&1
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

	local found_ids known_ids unknown_ids stale_ids
	found_ids="$(mktemp)"
	known_ids="$(mktemp)"
	unknown_ids="$(mktemp)"
	stale_ids="$(mktemp)"
	tmp_paths+=("$found_ids" "$known_ids" "$unknown_ids" "$stale_ids")

	sorted_ids_file "$output_file" "$found_ids"
	: >"$known_ids"
	if [ "$#" -gt 0 ]; then
		printf '%s\n' "$@" | sort -u >"$known_ids"
	fi
	comm -23 "$found_ids" "$known_ids" >"$unknown_ids"
	comm -13 "$found_ids" "$known_ids" >"$stale_ids"

	if [ ! -s "$found_ids" ]; then
		cat "$output_file"
		fail "$name failed without reporting Go vulnerability IDs"
		return
	fi

	if [ -s "$unknown_ids" ] || [ -s "$stale_ids" ]; then
		cat "$output_file"
		if [ -s "$unknown_ids" ]; then
			fail "$name reported new Go vulnerability IDs: $(tr '\n' ' ' <"$unknown_ids")"
		fi
		if [ -s "$stale_ids" ]; then
			fail "$name Go vulnerability allowlist is stale: $(tr '\n' ' ' <"$stale_ids")"
		fi
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
			nix shell --inputs-from "$repo_root" nixpkgs#govulncheck nixpkgs#go -c govulncheck -scan=module
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
			GO-2026-5024 \
			GO-2026-5025 \
			GO-2026-5026 \
			GO-2026-5027 \
			GO-2026-5028 \
			GO-2026-5029 \
			GO-2026-5030 \
			GO-2026-5320 \
			GO-2026-5942 \
			GO-2026-5970 \
			GO-2026-6603 \
			GO-2026-6610 \
			GO-2026-6611 \
			GO-2026-6612 \
			GO-2026-6617 \
			GO-2026-6629 \
			GO-2026-6809
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

	local gws_version
	gws_version="$(package_version "$system" googleworkspace-cli)"
	check_github_release_latest "googleworkspace/cli" "v${gws_version}"

	check_pins

	# GHSA-vfj7-8cjw-p6xm: braces 3.0.3 nested-pattern DoS, no fixed release.
	osv_audit_lock "oracle" "pkgs/oracle/package-lock.json" GHSA-vfj7-8cjw-p6xm

	local gws_src trueflow_src notion_src
	# Build the source so the lockfile exists even when the store lacks it.
	gws_src="$(nix build --no-link --print-out-paths "$repo_root#packages.${system}.googleworkspace-cli.src")"
	trueflow_src="$(input_path trueflow)"
	notion_src="$(input_path notion-cli)"

	cargo_audit_lock "pkgs/flow" "pkgs/flow/Cargo.lock"
	cargo_audit_lock "projects/omp-phone" "projects/omp-phone/Cargo.lock"
	cargo_audit_lock \
		"googleworkspace/cli" \
		"$gws_src/Cargo.lock" \
		RUSTSEC-2026-0098 \
		RUSTSEC-2026-0099 \
		RUSTSEC-2026-0104 \
		RUSTSEC-2026-0185 \
		RUSTSEC-2026-0258 \
		RUSTSEC-2026-0285 \
		RUSTSEC-2026-0338 \
		RUSTSEC-2026-0339 \
		RUSTSEC-2026-0340 \
		RUSTSEC-2026-0342 \
		RUSTSEC-2026-0346 \
		RUSTSEC-2026-0348 \
		RUSTSEC-2026-0349 \
		RUSTSEC-2026-0382
	cargo_audit_lock \
		"trueflow" \
		"$trueflow_src/trueflow/Cargo.lock"
	cargo_audit_lock \
		"voxtype (pkgs/voxtype)" \
		"pkgs/voxtype/Cargo.lock" \
		RUSTSEC-2026-0194 \
		RUSTSEC-2026-0195

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
