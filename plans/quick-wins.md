# Quick Wins Scan

## Scope
Parallel scan across bootstrap scripts, shell configs, i3/i3status configs, NixOS config, and Doom Emacs config.

## Legend
- `GREEN`: low-risk, high-value, should do now.
- `YELLOW`: useful but needs preference/behavior decision first.
- `RED`: likely skip for now.

## (A) Correctness / Logic / Overall Fixes
1. `A1` `GREEN` Fix installer root-context bug (`README` uses `sudo sh`, so `~` resolves to root and user files land under root home).
Refs: [README.md](/Users/jmq/src/dotfiles/README.md#L13), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L24), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L49), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L63)
2. `A2` `GREEN` Make installer idempotent and fail-fast (`set -euo pipefail`, guarded clones, safer symlink behavior for reruns).
Refs: [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L54), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L55), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L42)
3. `A3` `GREEN` Fix broken git alias `fixup` (currently malformed around `git rev-parse`).
Refs: [.gitconfig](/Users/jmq/src/dotfiles/.gitconfig#L13)
4. `A4` `GREEN` Fix `gptel-api-key` loading logic in Doom config (`insert-file-contents` does not return the key string as used here).
Refs: [.doom.d/config.el](/Users/jmq/src/dotfiles/.doom.d/config.el#L59)
5. `A5` `GREEN` Fix shell incompatibility in i3status command (`<(...)` process substitution breaks under `/bin/sh`).
Refs: [.i3/status_bar.toml](/Users/jmq/src/dotfiles/.i3/status_bar.toml#L3)

## (B) Security / Leaks / Privacy
1. `B1` `GREEN` Stop sourcing `~/.env` as code in installer path (high-risk especially with current `sudo` invocation model).
Refs: [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L49)
2. `B2` `YELLOW` Replace plaintext git credential storage with OS-backed helper (`osxkeychain`, `libsecret`, or GCM).
Refs: [.gitconfig](/Users/jmq/src/dotfiles/.gitconfig#L16), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L43)
3. `B3` `YELLOW` Harden SSH defaults explicitly on NixOS (`PasswordAuthentication`, `PermitRootLogin`, optional `KbdInteractiveAuthentication`).
Refs: [nixos/configuration.nix](/Users/jmq/src/dotfiles/nixos/configuration.nix#L64)
4. `B4` `YELLOW` Reassess external network calls from status bar (`wttr.in`, `1.1.1.1`) if privacy-sensitive.
Refs: [.i3/status_bar.toml](/Users/jmq/src/dotfiles/.i3/status_bar.toml#L3), [.i3/status_bar.toml](/Users/jmq/src/dotfiles/.i3/status_bar.toml#L14)

## (C) Perf Wins / Optimizations
1. `C1` `GREEN` Add timeouts and lighter probes for status bar custom commands (`curl --max-time`, smaller/fewer ping calls).
Refs: [.i3/status_bar.toml](/Users/jmq/src/dotfiles/.i3/status_bar.toml#L3), [.i3/status_bar.toml](/Users/jmq/src/dotfiles/.i3/status_bar.toml#L14)
2. `C2` `YELLOW` Trim duplicate or overlapping Nix packages (duplicate `fd`, multiple Node versions, duplicate yarn entry points).
Refs: [nixos/configuration.nix](/Users/jmq/src/dotfiles/nixos/configuration.nix#L153), [nixos/configuration.nix](/Users/jmq/src/dotfiles/nixos/configuration.nix#L178), [nixos/configuration.nix](/Users/jmq/src/dotfiles/nixos/configuration.nix#L237), [nixos/configuration.nix](/Users/jmq/src/dotfiles/nixos/configuration.nix#L241)
3. `C3` `YELLOW` Revisit zsh `TMOUT=1` + `TRAPALRM` prompt reset behavior for potential wakeup churn.
Refs: [.zshrc](/Users/jmq/src/dotfiles/.zshrc#L17)

## (D) Suspected Removals
1. `D1` `GREEN` Remove legacy `.config/i3status/i3status.py` if fully unused (current i3 bar uses `i3status-rs` TOML).
Refs: [.i3/config](/Users/jmq/src/dotfiles/.i3/config#L154), [.config/i3status/i3status.py](/Users/jmq/src/dotfiles/.config/i3status/i3status.py#L1)
2. `D2` `YELLOW` Remove/archive `bin/i3-renameworkspaces.pl` if `i3wsr` fully supersedes it.
Refs: [.i3/config](/Users/jmq/src/dotfiles/.i3/config#L8), [bin/i3-renameworkspaces.pl](/Users/jmq/src/dotfiles/bin/i3-renameworkspaces.pl#L1)
3. `D3` `GREEN` Remove empty placeholder `.config/prefs`.
Refs: [.config/prefs](/Users/jmq/src/dotfiles/.config/prefs)
4. `D4` `YELLOW` Remove Doom bootstrap from installer once handcrafted Emacs setup is live.
Refs: [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L16), [bin/install.sh](/Users/jmq/src/dotfiles/bin/install.sh#L19)

## Proposed First Implementation Batch
- `A1`, `A2`, `A3`, `A5`, `B1`, `C1`, `D1`, `D3`
