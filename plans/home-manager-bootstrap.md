# Home Manager Bootstrap Plan

## Goal
Add a minimal Home Manager setup in this repo that works on macOS and can grow incrementally.

## Scope (Initial)
1. Add Home Manager flake input.
2. Add a small `home/` module layout:
- shared config (`home/common.nix`)
- macOS config (`home/darwin.nix`)
- host entrypoint (`home/hosts/jmq-macos.nix`)
3. Expose macOS Home Manager targets in `flake.nix`.
4. Document activation commands in README.

## Target Commands
- Apple Silicon macOS:
`HM_BOOTSTRAP_USER="$USER" home-manager switch --impure --flake .#macos-aarch64`
- Intel macOS:
`HM_BOOTSTRAP_USER="$USER" home-manager switch --impure --flake .#macos-x86_64`

## Notes
- This uses standalone Home Manager (no `nix-darwin` yet).
- NixOS system config remains separate.
- Shared modules are designed for later Linux/macOS reuse.
