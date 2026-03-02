# Emacs Handcrafted Migration Plan (No Doom)

## Objective
Replace Doom Emacs with a modular handcrafted Emacs config while preserving your daily workflow, especially:
- `SPC` leader-menu muscle memory
- existing Evil-centric keybinding behavior
- current language/tooling coverage

## Design Principles
- Behavior-first migration: preserve key UX before reorganizing internals.
- Modular structure: split config into small, purpose-specific files.
- Progressive cutover: run Doom and handcrafted config side-by-side until parity.
- Reproducibility: keep package versions pinned/locked.

## Precedent and Approach
There is strong precedent for this pattern in the Emacs community:
- Doom/Spacemacs users moving to vanilla Emacs while keeping leader-key UX via `general.el` + `which-key`.
- Modular `early-init.el` + `init.el` + `lisp/` layouts for maintainable long-term configs.
- `use-package`-based, piece-by-piece migration where each subsystem is replaced and validated.

Recommended approach for your setup:
- Start with `straight.el` + `use-package` for closest package behavior to Doom.
- Rebuild core interaction model first (`evil`, leader keys, completion/search, project workflows).
- Port language tooling and app workflows (mu4e/org/rss) after core UX is stable.

## Target Config Structure
```text
.config/emacs/
├── early-init.el
├── init.el
├── lisp/
│   ├── core/
│   │   ├── core-ui.el
│   │   ├── core-keys.el
│   │   ├── core-editing.el
│   │   ├── core-completion.el
│   │   └── core-project.el
│   ├── lang/
│   │   ├── lang-rust.el
│   │   ├── lang-go.el
│   │   ├── lang-python.el
│   │   └── lang-web.el
│   ├── tools/
│   │   ├── tool-magit.el
│   │   ├── tool-lsp.el
│   │   ├── tool-dap.el
│   │   ├── tool-org.el
│   │   └── tool-mail.el
│   └── local/
│       └── jordan-keybinds.el
├── snippets/
└── custom.el
```

## Current Behavior to Preserve (From Existing `.doom.d`)
1. Leader model: `SPC` global leader and `,` localleader.
2. Evil model: `evil` everywhere plus custom ijkl directional remaps.
3. Completion/search: `vertico`, `company`, and your movement customizations in minibuffer/Vertico/Company.
4. Git workflow: `magit` with extensive section-navigation key customizations.
5. LSP/debug: `lsp-mode`, Rust + DAP (`dap-cpptools`, templates).
6. Org workflow: `org-directory`, inline image refresh after babel execution, `ox-reveal`, and Jira export helper.
7. Extra packages: `gptel`, `my-whisper`, `org-jira`, `org-reveal`, `dap-mode`.

## Package Strategy Options
1. `straight.el` + `use-package` (Recommended)
- Closest to Doom package model
- Easy pinning/lockfile behavior
- Smooth package-by-package migration
2. `package.el` + `use-package`
- Simpler and built-in
- Less robust pinning for larger setups
3. Nix-first package provisioning (`emacsWithPackages` / overlays)
- Highest reproducibility with your broader nixification goal
- Highest migration overhead initially

## Migration Phases

### Phase 0: Inventory and Baseline
- Produce a command/keybinding inventory from current Doom usage.
- Mark must-have vs nice-to-have behavior.
- Record startup time baseline.

Exit criteria:
- Written parity checklist for key workflows.

### Phase 1: Bootstrap Handcrafted Skeleton
- Create `.config/emacs/early-init.el`, `init.el`, and `lisp/` module tree.
- Install package manager bootstrap (`straight.el`) and `use-package`.
- Wire module loading order and isolate `custom.el`.

Exit criteria:
- Emacs starts cleanly with new skeleton and package bootstrap.

### Phase 2: Rebuild Interaction Core (Highest Priority)
- Add `evil`, `evil-collection`, `general`, `which-key`.
- Recreate `SPC` leader tree and `,` localleader semantics.
- Port custom movement/key translations (`C-i` to `H-i`, ijkl mapping behavior).
- Set core UI defaults (theme, fonts, relative line numbers).

Exit criteria:
- Leader menu and primary movement/navigation muscle memory restored.

### Phase 3: Completion/Search/Project UX
- Add `vertico`, `orderless`, `marginalia`, `consult`, `embark`.
- Add `company` (or evaluate `corfu` only after parity).
- Restore minibuffer/Vertico/Company key customizations.
- Add project utilities (`project.el` and/or `projectile` parity layer).

Exit criteria:
- File search, command execution, and completion behavior feels equivalent.

### Phase 4: Tooling and Language Stack
- Port magit and your section-navigation bindings.
- Port LSP stack and language hooks (Rust, Go, Python, JS, Nix, etc).
- Recreate DAP templates and debugger defaults.
- Port formatting-on-save and syntax/spell/grammar behavior.

Exit criteria:
- Core development workflows run without Doom dependencies.

### Phase 5: Org/Mail/App Workflows
- Port org customizations and export helpers (`ox-reveal`, Jira conversion helper).
- Port mu4e/gmail setup and org integrations.
- Port RSS and any remaining app-level integrations.
- Port `gptel`, `my-whisper`, and related secrets loading.

Exit criteria:
- Personal productivity workflows match prior Doom setup.

### Phase 6: Doom Removal and Cleanup
- Remove `.doom.d` from bootstrap path.
- Delete Doom-specific commands/docs from install workflow.
- Keep compatibility notes for any intentionally changed behavior.

Exit criteria:
- Clean startup with no Doom package or macro references.

## Keybinding Compatibility Strategy
- Define keymaps in one place (`core-keys.el`) using `general.el`.
- Recreate Doom-like leader categories (`SPC f`, `SPC b`, `SPC p`, `SPC g`, `SPC w`, etc).
- Use `which-key` labels to preserve discoverability.
- Keep local mode bindings in per-module files, but register their prefixes centrally.

## Risks and Mitigations
- Risk: keybinding regressions.
- Mitigation: maintain a written parity checklist and verify each prefix map.
- Risk: startup/performance regressions.
- Mitigation: benchmark during each phase; defer optional packages.
- Risk: package churn.
- Mitigation: pin package revisions and update intentionally.
- Risk: over-coupling to migration hacks.
- Mitigation: isolate temporary compatibility code in `lisp/local/`.

## Open Questions
1. Package manager baseline: standardize on `straight.el` first for Doom-like behavior, or jump directly to Nix-managed package builds for tighter reproducibility?
2. LSP client choice: keep `lsp-mode` for closest parity, or selectively move some languages to `eglot` for lower overhead?
3. Completion backend: keep `company` for parity now, or adopt `corfu` + `cape` as the newer lightweight path?
4. Project tooling: use built-in `project.el` + `consult` exclusively, or keep `projectile` compatibility during migration?
5. Syntax parsing: rely on modern built-in tree-sitter (`treesit`) where possible, or keep package-based `tree-sitter` for consistency with old behavior?
6. Leader-key stack: use `general.el` + `which-key` only, or evaluate alternatives like `meow`/`ryo-modal` for long-term key ergonomics?
7. Evil ecosystem depth: port all current Evil remaps exactly first, or intentionally normalize unusual mappings (`ijkl`) over time?
8. Search/navigation UX: keep Doom-like command palette behavior strictly, or adopt more `consult`/`embark`-native patterns even if key flows change?
9. Startup optimization strategy: set explicit startup budgets and gate phase completion on measured cold/warm timings?
10. Async/perf helpers: adopt `gcmh`, tuned GC thresholds, and deferred loading policy globally from day one?
11. UI/theme strategy: keep `doom-themes` for visual continuity, or switch to newer built-in/third-party themes with lower dependency surface?
12. Minibuffer stack depth: add `embark`, `embark-consult`, and `wgrep` immediately, or postpone until basic parity is proven?
13. Org ecosystem scope: keep existing org stack minimal, or modernize with additions like `org-modern` and updated export tooling now?
14. Mail/RSS future: keep mu4e/rss exactly as-is first, or reassess those workflows while moving away from Doom modules?
15. Configuration style: enforce module-per-domain files only, or allow a temporary `compat.el` layer to accelerate migration?
16. Community precedent sampling: which vanilla configs should we benchmark against before implementation for keymap architecture, startup approach, and package choices?
17. Secrets and local state: keep API keys file-based, or move to `auth-source`/`pass`/OS keychain-backed lookup?

## Definition of Done
- `SPC` and localleader flows are functionally equivalent for daily usage.
- No Doom macros (`map!`, `after!`, `use-package!`, `setq!`) remain.
- Startup is reliable across Linux and macOS.
- Config is modular, documented, and ready to integrate with Home Manager.

## Immediate Next Steps
1. Generate a concrete keybinding parity checklist from current usage.
2. Create handcrafted config skeleton files in-repo (without removing Doom yet).
3. Implement Phase 2 first (leader + Evil + which-key), then test daily for a week before Phase 3.
