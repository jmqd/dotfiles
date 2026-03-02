# TODO

## 1) Nixify dotfiles
- [ ] Decide target model: `NixOS` system config vs `nix` package manager + `home-manager`.
- [ ] Create a flake-based layout for reproducible setup.
- [ ] Move user-facing dotfiles/config into `home-manager` modules.
- [ ] Package or wire in local scripts from `bin/`.
- [ ] Define a clean bootstrap path for a brand-new machine.

## 2) Remove Doom Emacs dependency
- [ ] Inventory what is currently provided by `.doom.d/`.
- [ ] Create a piecewise Emacs config (`early-init.el`, `init.el`, and modular files).
- [ ] Set up package management (`use-package` with `package.el` or `straight.el`).
- [ ] Port keybindings, completion, LSP, org, and language tooling incrementally.
- [ ] Document migration notes and parity gaps during transition.
- [ ] Remove Doom-specific install/bootstrapping from machine setup.

## 3) Fixes and modernization
- [ ] Audit shell setup (`.bashrc`, `.zshrc`) for portability and startup performance.
- [ ] Modernize install/bootstrap docs and workflows.
- [ ] Add quality checks where useful (`shellcheck`, formatting, Nix checks).
- [ ] Refresh aging configs (tmux, terminal, WM, git) against current defaults.
