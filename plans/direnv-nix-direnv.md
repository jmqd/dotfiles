# Direnv / nix-direnv Plan

## Goal
Add a cross-platform, Home Manager-managed project environment flow that works on macOS and NixOS and makes Nix dev shells automatic on `cd`.

## Options

### 1. Plain `direnv`
- Use `direnv` only.
- Good for generic per-directory env vars and non-Nix projects.
- Lowest complexity, but weaker Nix ergonomics.

### 2. `direnv` + built-in `use nix` / `use flake`
- Use `direnv` and rely on its built-in Nix integration.
- Simpler than adding another tool.
- Acceptable, but not the best performance or caching story for frequent Nix shell use.

### 3. `direnv` + `nix-direnv`
- Use `direnv` for shell hooks and trust model.
- Use `nix-direnv` for `use nix` / `use flake`.
- Best fit for this repo and workflow.
- Recommended.

### 4. `direnv` + `nix-direnv` + extra acceleration
- Keep the recommended setup above.
- Consider an extra layer like async/background loading only if startup latency is still annoying.
- Not needed for the first pass.

## Recommendation
Use Home Manager to enable:
- `programs.direnv.enable = true`
- `programs.direnv.nix-direnv.enable = true`
- shell integration for the shell you actually use (`zsh` now, `fish` if you switch)

Use flake-native project entry with:
- `.envrc` containing `use flake`

This gives:
- shared macOS + NixOS behavior
- automatic shell activation on directory entry
- better caching than plain `direnv`
- no daemon requirement

## Non-Goals
- Do not store secrets directly in `.envrc`.
- Do not add per-project custom logic until the base flow is stable.
- Do not try to solve every shell migration question in the same change.

## Proposed Home Manager Shape

### New module
- `home/direnv.nix`

### Initial contents
- install and enable `direnv`
- enable `nix-direnv`
- enable shell integration for the current shell
- optionally add a small shared `direnv.toml`

### Example target shape
```nix
{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };
}
```

If shell changes later:
- disable Zsh integration
- enable Fish integration instead

## Repo-Level Usage

### For flake-based repos
Add:
```bash
use flake
```
to `.envrc`.

### For non-flake repos
Fallback:
```bash
use nix
```

### Trust model
- `direnv` requires explicit approval with `direnv allow`
- this is a feature, not a nuisance
- keep `.envrc` small and auditable

## Rollout Plan

### Phase 1: Base tool
1. Add `home/direnv.nix`
2. Import it from `home/common.nix`
3. Enable integration for current shell
4. Apply on macOS host

Exit criteria:
- `direnv version` works
- `direnv status` works
- shell hook is active

### Phase 2: Repo bootstrap
1. Add `.envrc` to this repo
2. Start with `use flake`
3. Run `direnv allow`

Exit criteria:
- entering the repo auto-loads the dev environment
- `gitleaks`, `shellcheck`, `shfmt`, `gws` are available on entry without manual `nix develop`

### Phase 3: Policy and ergonomics
1. Decide whether to commit `.envrc` broadly in repos
2. Add shared conventions for local overrides if needed
3. Decide whether to add a minimal `direnv.toml`

Exit criteria:
- consistent setup pattern across personal repos

## Open Questions
1. Keep `zsh` integration for now, or hold this until a shell migration lands?
2. Should `.envrc` be committed in all flake repos, or only selected ones?
3. Do you want a shared `direnv.toml`, or keep defaults first?
4. Do you want local override patterns such as `.envrc.local` from day one?
5. Should this repo auto-load only the dev shell, or also project-specific env vars later?

## Verification
1. `direnv version`
2. `direnv status`
3. `cd ~/src/dotfiles`
4. `direnv allow`
5. verify the prompt reloads and tools are present:
   - `command -v gitleaks`
   - `command -v shellcheck`
   - `command -v shfmt`
   - `command -v gws`

## Why This Path
- `direnv` is the shell hook and approval model.
- `nix-direnv` is the better Nix integration layer.
- Home Manager is the right place to make this portable across macOS and NixOS.
