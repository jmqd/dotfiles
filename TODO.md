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

## 4) Add style settings for pi

## 5) Agent sandboxes / fleet runner
- [ ] Design a reproducible multi-agent sandbox runner for pi on Linux.
- [ ] Use per-agent worktrees cloned from a local bare mirror, not the live repo checkout.
- [ ] Provide an isolated shared Nix daemon/store for agents that does not touch the host `/nix/store`.
- [ ] Make the repo dev environment available inside each sandbox so tools "just work" (`nix develop` / `devenv`).
- [ ] Support running N agents in N sandboxes with permission gates disabled inside the sandbox boundary.
- [ ] Support both headless orchestration and optional interactive attach/debug for a specific agent.
- [ ] Write down the target design and rollout plan.
