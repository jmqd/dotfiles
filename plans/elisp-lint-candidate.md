# Elisp Lint Candidate Plan

## Goal
Add useful Elisp linting to this repo without creating noisy failures during the Doom-to-vanilla migration.

## Constraints
- The current Emacs config is still Doom-shaped.
- Doom macros such as `doom!`, `map!`, `use-package!`, `setq!`, and `package!` are not valid under plain `emacs --batch -Q`.
- A good lint plan must distinguish between:
  - current Doom-era files
  - future handcrafted vanilla files

## Non-Goals
- Do not block pushes on stylistic warnings during the Doom era.
- Do not introduce a complex Elisp toolchain before the vanilla config skeleton exists.
- Do not treat package-oriented lint as mandatory for personal config modules.

## Candidate Linters
1. Built-in Emacs byte compilation
- Best for real code issues: undefined functions, warnings, compile errors.
- Strongest baseline once files are loadable in their intended environment.

2. Built-in `checkdoc`
- Useful for doc/style cleanup.
- Low priority for personal config until file layout stabilizes.

3. `relint`
- Good targeted check for regex-heavy code.
- Only useful where regex complexity actually exists.

4. `package-lint`
- Good for package metadata and public package conventions.
- Usually the wrong default for private personal config files.

5. `elisp-lint`
- Can orchestrate multiple checks.
- Better as a later convenience layer, not a first dependency.

## File Classes
### Doom-era files
- `.doom.d/init.el`
- `.doom.d/config.el`
- `.doom.d/packages.el`

### Vanilla-era files
- `.config/emacs/early-init.el`
- `.config/emacs/init.el`
- `.config/emacs/lisp/**/*.el`

## Lint Matrix
1. `.doom.d/init.el`
- No generic batch compilation under `-Q`.
- At most, syntax/load validation in a Doom-aware environment.

2. `.doom.d/config.el`
- No generic batch compilation under `-Q`.
- Optional/manual validation only while Doom remains the runtime.

3. `.doom.d/packages.el`
- Do not byte-compile.
- Treat as declarative package input, not normal Elisp source.

4. Vanilla config modules
- Byte-compile by default.
- Add selective `checkdoc` later if signal is good.
- Add `relint` only for files that justify it.

5. Package-style files, if any appear later
- Consider `package-lint`.

## Nix Integration Options
1. Minimal baseline
- Add `emacs` to the flake dev shell.
- Add a repo script such as `bin/lint-elisp.sh`.
- Run direct batch commands, not a meta-runner.

2. Extended package-aware setup
- Use `emacsWithPackages` for `relint` / `package-lint` if and when needed.
- Keep the script as the stable interface.

3. Eask-based workflow
- Reasonable only if the Elisp side grows into a fuller project.
- Not recommended for the first pass.

## Recommended Rollout
### Phase 0: Scope and policy
- Define file globs and exclusions up front.
- Decide which lint rules are advisory versus blocking.
- Explicitly separate Doom-era and vanilla-era handling.

Exit criteria:
- There is no ambiguity about which files are linted and how.

### Phase 1: Manual vanilla-era baseline
- Add `bin/lint-elisp.sh`.
- If no handcrafted vanilla files exist yet, the script should exit successfully with a clear no-op message.
- For vanilla files, run byte-compilation in batch mode.
- Do not add this to pre-push yet.

Exit criteria:
- Manual lint runs are fast, predictable, and low-noise.

### Phase 2: Optional Doom-era checks
- If useful, add a manual Doom-aware validation path for `.doom.d/` files.
- Keep this separate from the vanilla lint path.
- Do not gate pushes on Doom-era style checks.

Exit criteria:
- Doom validation exists only if it provides real signal.

### Phase 3: Hook integration for vanilla files
- Add Elisp lint to `.githooks/pre-push`.
- Lint only changed tracked `.el` files in the vanilla config paths.
- Fail on byte-compile errors.
- Keep style-oriented checks warn-only at first.

Exit criteria:
- Pre-push catches real regressions without routine churn.

### Phase 4: Extended lint set
- Add `relint` for regex-heavy files if needed.
- Add selective `checkdoc` for modules where style consistency matters.
- Add `package-lint` only if package-style modules appear.

Exit criteria:
- Additional linters improve signal instead of expanding false positives.

## Initial Recommendation
1. Do not gate Doom-era files with plain `emacs --batch -Q` lint.
2. Add a manual `bin/lint-elisp.sh` that no-ops until handcrafted files exist.
3. Make byte-compilation the first real blocking signal.
4. Defer `checkdoc`, `package-lint`, and `elisp-lint` until the handcrafted layout is present.
5. When hook integration comes, lint changed vanilla `.el` files only.

## Open Questions
1. Do we want any Doom-aware validation at all, or should all real linting wait for the handcrafted config?
2. Should the first manual lint target only `.config/emacs/**/*.el`, or also support a future `lisp/` root outside that tree?
3. When the handcrafted config lands, should `checkdoc` remain advisory permanently?
4. Is `relint` worth carrying from the start, or only once regex-heavy helpers appear?
5. Should hook integration operate on staged files, changed tracked files, or the full vanilla tree?
6. Do we want a single stable `bin/lint-elisp.sh` entrypoint even if the underlying implementation changes later?
