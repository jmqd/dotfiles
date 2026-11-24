#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

failures=0
updates=0
residuals=0
tmp_paths=()
flow_bin=""
osv_scanner_bin=""
cargo_audit_bin=""
govulncheck_dir=""
go_dir=""
cargo_audit_db_fetched=0

cleanup() {
	local path
	for path in ${tmp_paths[@]+"${tmp_paths[@]}"}; do
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

note_upgrade() {
	local name="$1" current="$2" latest="$3"
	if [ "$current" = "$latest" ]; then
		ok "$name is current at $current"
	else
		updates=$((updates + 1))
		printf 'upgrade available: %s %s -> %s\n' "$name" "$current" "$latest"
	fi
}

# Header lines for `curl --header @file`, so the token never appears in the
# process list.
github_api_headers() {
	printf '%s\n' "Accept: application/vnd.github+json" "User-Agent: dotfiles-audit-deps"
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN"
	fi
}

github_release_latest_api() {
	local repo="$1"
	curl --fail --silent --show-error --location --header @<(github_api_headers) "https://api.github.com/repos/${repo}/releases/latest" |
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
	report="$("$flow_bin" --output json pin check)" || true
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
	"$osv_scanner_bin" scan --format json --lockfile "$lock_file" >"$output_file" 2>"$stderr_file"
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

	# Only the first run needs to fetch the advisory database.
	local no_fetch=""
	if [ "$cargo_audit_db_fetched" -eq 1 ]; then
		no_fetch="--no-fetch"
	fi

	set +e
	"$cargo_audit_bin" audit ${no_fetch:+"$no_fetch"} --file "$lock_file" --json >"$json_file" 2>"$json_stderr"
	set -e

	# Empty or error output must fail; jq alone accepts empty input.
	if ! jq -e '.vulnerabilities.list | type == "array"' "$json_file" >/dev/null 2>&1 ||
		! jq -r '[.vulnerabilities.list[].advisory.id] | sort | .[]' "$json_file" | sort -u >"$actual_file"; then
		cat "$json_stderr" "$json_file"
		fail "cargo audit JSON failed for $name"
		return
	fi
	cargo_audit_db_fetched=1

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

	ok "cargo audit passed for $name"
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

	local default_cache_base="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-audit-go"
	local go_mod_cache="${GOMODCACHE:-$default_cache_base/mod}"
	local go_build_cache="${GOCACHE:-$default_cache_base/build}"
	if ! mkdir -p "$go_mod_cache" "$go_build_cache" 2>/dev/null; then
		go_mod_cache="$(mktemp -d)"
		go_build_cache="$(mktemp -d)"
		tmp_paths+=("$go_mod_cache" "$go_build_cache")
	fi

	cp -R "$notion_src"/. "$work_dir"/
	chmod -R u+w "$work_dir"

	set +e
	(
		cd "$work_dir"
		env \
			PATH="${govulncheck_dir}:${go_dir}:${PATH}" \
			GOMODCACHE="$go_mod_cache" \
			GOCACHE="$go_build_cache" \
			GOFLAGS="${GOFLAGS:-} -modcacherw" \
			govulncheck -scan=module
	) >"$output_file" 2>&1
	status=$?
	set -e

	if [ "$status" -eq 0 ]; then
		ok "lox/notion-cli govulncheck is clean"
	else
		check_known_go_vulns \
			"lox/notion-cli govulncheck" \
			"$output_file" \
			GO-2026-6860 \
			GO-2026-6866 \
			GO-2026-6911
	fi
}

run_cargo_audits() {
	local gws_src="$1" trueflow_src="$2"
	cargo_audit_lock "pkgs/flow" "pkgs/flow/Cargo.lock"
	cargo_audit_lock "projects/omp-phone" "projects/omp-phone/Cargo.lock"
	cargo_audit_lock "projects/spotify-export" "projects/spotify-export/Cargo.lock"
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
		RUSTSEC-2026-0195 \
		RUSTSEC-2026-0459
}

cleanup_group_tmp() {
	if [ -n "${TMPDIR:-}" ]; then
		rm -rf "$TMPDIR"
	fi
}

# Runs one audit group in an isolated scope with its own TMPDIR so background
# subshell temp files and counters stay independent of the parent shell.
run_group_isolated() {
	local idx="$1"
	shift
	local tmp_paths=() failures=0 updates=0 residuals=0
	TMPDIR="$audit_dir/tmp-${idx}"
	export TMPDIR
	mkdir -p "$TMPDIR"
	trap cleanup_group_tmp EXIT
	"$@" >"$audit_dir/group-${idx}.out" 2>&1
	printf '%d %d %d\n' "$failures" "$updates" "$residuals" >"$audit_dir/group-${idx}.counts"
}

spawn_group() {
	local idx="$1"
	shift
	run_group_isolated "$idx" "$@" &
	group_pids["$idx"]=$!
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

	# git+file reads the tracked tree in place; a plain path makes Nix copy the
	# whole working directory, ignored caches included, into the store.
	local meta_json system gws_version trueflow_src notion_src
	meta_json="$(
		DOTFILES_AUDIT_ROOT="$repo_root" nix eval --impure --json --expr '
			let
				flake = builtins.getFlake ("git+file://" + builtins.getEnv "DOTFILES_AUDIT_ROOT");
				system = builtins.currentSystem;
				pkgsFor = builtins.getAttr system flake.packages;
			in
			{
				inherit system;
				gwsVersion = pkgsFor.googleworkspace-cli.version;
				trueflowSrc = flake.inputs.trueflow.outPath;
				notionSrc = flake.inputs.notion-cli.outPath;
			}
		'
	)"
	IFS=$'\t' read -r system gws_version trueflow_src notion_src < <(
		jq -r '[.system, .gwsVersion, .trueflowSrc, .notionSrc] | @tsv' <<<"$meta_json"
	)
	ok "current system is $system"

	# Resolve every Nix-managed audit tool and source in one batched build.
	local flake_ref="git+file://${repo_root}"
	local build_json osv_out cargo_audit_out govulncheck_out go_out gws_src flow_out
	build_json="$(
		nix build --no-link --json --inputs-from "$flake_ref" \
			"nixpkgs#osv-scanner" \
			"nixpkgs#cargo-audit" \
			"nixpkgs#govulncheck" \
			"nixpkgs#go" \
			"${flake_ref}#packages.${system}.googleworkspace-cli.src" \
			"${flake_ref}#packages.${system}.flow"
	)"
	IFS=$'\t' read -r osv_out cargo_audit_out govulncheck_out go_out gws_src flow_out < <(
		jq -r '[.[] | (.outputs.bin // .outputs.out)] | @tsv' <<<"$build_json"
	)

	osv_scanner_bin="$osv_out/bin/osv-scanner"
	cargo_audit_bin="$cargo_audit_out/bin/cargo-audit"
	govulncheck_dir="$govulncheck_out/bin"
	go_dir="$go_out/bin"
	flow_bin="$flow_out/bin/flow"

	local bin
	for bin in "$osv_scanner_bin" "$cargo_audit_bin" "$govulncheck_dir/govulncheck" "$go_dir/go" "$flow_bin"; do
		if [ ! -x "$bin" ]; then
			fail "could not resolve executable: $bin"
			exit 1
		fi
	done

	local audit_dir
	audit_dir="$(mktemp -d)"
	tmp_paths+=("$audit_dir")

	local -a group_pids=()
	spawn_group 1 check_github_release_latest "googleworkspace/cli" "v${gws_version}"
	spawn_group 2 check_pins
	spawn_group 3 osv_audit_lock "oracle" "pkgs/oracle/package-lock.json"
	spawn_group 4 run_cargo_audits "$gws_src" "$trueflow_src"
	spawn_group 5 govulncheck_notion_cli "$notion_src"

	local idx rc g_fail g_upd g_res
	for idx in 1 2 3 4 5; do
		rc=0
		g_fail=0
		g_upd=0
		g_res=0
		wait "${group_pids[$idx]}" || rc=$?
		if [ -f "$audit_dir/group-${idx}.out" ]; then
			cat "$audit_dir/group-${idx}.out"
		fi
		if [ -f "$audit_dir/group-${idx}.counts" ]; then
			read -r g_fail g_upd g_res <"$audit_dir/group-${idx}.counts"
			failures=$((failures + g_fail))
			updates=$((updates + g_upd))
			residuals=$((residuals + g_res))
			if [ "$rc" -ne 0 ] && [ "$g_fail" -eq 0 ]; then
				fail "audit group $idx exited with status $rc"
			fi
		else
			fail "audit group $idx terminated unexpectedly (exit $rc)"
		fi
	done

	section "summary"
	printf 'updates available: %s\n' "$updates"
	printf 'known residual advisories: %s\n' "$residuals"
	printf 'unexpected failures: %s\n' "$failures"

	if [ "$failures" -gt 0 ]; then
		exit 1
	fi
}

main "$@"
