#!/usr/bin/env bash
set -euo pipefail

rustup_bin="${RUSTUP_BIN:-rustup}"
toolchain="${1:-stable}"
shift || true

profile="${RUSTUP_PROFILE:-minimal}"
if [[ $# -gt 0 ]]; then
  components=("$@")
else
  components=(rustfmt clippy rust-analyzer)
fi

if ! command -v "$rustup_bin" >/dev/null 2>&1; then
  echo "rustup not found: $rustup_bin" >&2
  exit 1
fi

if "$rustup_bin" show active-toolchain >/dev/null 2>&1; then
  active_toolchain="$($rustup_bin show active-toolchain)"
  echo "Rust toolchain already initialized: $active_toolchain"
  exit 0
fi

echo "Initializing rustup default toolchain: $toolchain (profile: $profile)"
"$rustup_bin" toolchain install "$toolchain" --profile "$profile"
"$rustup_bin" default "$toolchain"

if [[ ${#components[@]} -gt 0 ]]; then
  echo "Installing rustup components: ${components[*]}"
  "$rustup_bin" component add "${components[@]}"
fi

echo "Rust bootstrap complete."
