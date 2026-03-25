# Emacs Handcrafted Migration Plan (No Doom)

## Objective
Replace Doom Emacs with a handcrafted Emacs config that preserves your **daily UX and functionality**, not necessarily the same package set.

Key idea:
- **Same or similar workflow matters more than package parity.**
- If a newer or simpler package gives you equivalent UX, that is acceptable.
- Migration should be driven by what you actually use every day, not by trying to reproduce Doom wholesale.

## What “Success” Means
The handcrafted config is successful when you can use it as a daily driver for normal development work with minimal friction.

That means preserving or approximating:
- Evil/modal editing
- leader-key workflow
- project switching and project file finding
- ripgrep/search workflow
- magit workflow
- basic Org workflow
- LSP/completion/diagnostics workflow
- daemon + `emacsclient` workflow

## Non-Goals
- Do **not** port every Doom module just because it is enabled.
- Do **not** preserve Doom internals, macros, or package choices unless they are the best current fit.
- Do **not** redesign your entire editing philosophy during the migration.
- Do **not** block on mail/RSS/app workflows before the core daily-driver flow works.

## Guiding Principles
1. **Daily workflow first**
   - Migrate the commands and flows you use constantly before anything else.
2. **UX over implementation**
   - Preserve behavior and ergonomics, not specific packages.
3. **Side-by-side cutover**
   - Doom and handcrafted config must be runnable separately until parity is good enough.
4. **Add missing things when they hurt**
   - After the core is usable, run it daily and add missing leader keys / commands incrementally.
5. **Prefer simpler implementations when they meet the UX bar**
   - Example: `project.el` + `consult` may be fine if it gives you the same practical project/file/search flow as Projectile.

## Package Choice Policy
Package choice is explicitly flexible.

Examples:
- `Projectile` may remain, or may be replaced by `project.el` + `consult` if the workflow feels right.
- `lsp-mode` may remain, or some languages may move to `eglot` if the user experience is good enough.
- `company` may remain, or completion may move to `corfu`/`cape` if parity is acceptable.
- `general.el` + `which-key` is a likely leader-key stack, but another approach is acceptable if it preserves the workflow.

Decision rule:
- **Keep or adopt whatever gives near-equivalent UX with lower complexity and lower maintenance cost.**

## Side-by-Side Runtime Strategy
Do not replace Doom in place at the beginning.

The migration needs two runnable editor paths:
1. **Current Doom setup**
2. **Handcrafted setup**

Requirements:
- separate config roots
- separate package state
- separate daemon/server names if daemons are used
- explicit launcher commands/scripts for each runtime

The point is to avoid cross-contamination while you compare behavior.

## Current Daily-Use Starter Backlog
These are the first workflows to bring up in the handcrafted config.

### Starter daily-driver TODO list
- [ ] Evil/modal editing works reliably.
- [ ] Your custom movement semantics are restored enough for daily use.
  - `ijkl` directional behavior
  - `C-i` → `H-i` translation if still needed
- [ ] `SPC` leader key works.
- [ ] `which-key` or equivalent discoverability is in place.
- [ ] File-finding workflow is usable.
- [ ] Buffer switching workflow is usable.
- [ ] Project switching workflow is usable.
- [ ] Project file finding is usable.
- [ ] Project search via ripgrep is usable.
- [ ] Magit is usable for normal git work.
  - status
  - stage/unstage
  - commit
  - diff/review
- [ ] Magit section navigation feels right.
- [ ] Window navigation/splitting is usable.
- [ ] Basic Org workflow is usable.
  - open/edit Org files comfortably
  - `org-directory` works as expected
  - capture/refile/agenda can be added in usage order if needed
- [ ] LSP works in primary languages.
- [ ] Completion, diagnostics, and formatting are good enough for daily coding.
- [ ] `emacs --daemon` / user service workflow works if you want it.
- [ ] `emacsclient -c` and `emacsclient -n` work correctly.
- [ ] Git commit editor flow works.

### Starter package candidates
These are candidates, not commitments:
- Evil stack:
  - `evil`
  - `evil-collection`
- Leader/discoverability:
  - `general.el`
  - `which-key`
- Completion/search/project UX:
  - `vertico`
  - `orderless`
  - `marginalia`
  - `consult`
  - `embark` (optional early)
  - `projectile` **or** `project.el`-based workflow
  - ripgrep via `consult-ripgrep`, `deadgrep`, or equivalent
- Git:
  - `magit`
- Org:
  - built-in `org`
  - optional org add-ons only when the core workflow needs them
- LSP:
  - `lsp-mode` **or** `eglot`
- Completion backend:
  - `company` **or** `corfu`/`cape`

## Current Explicit Behavior Worth Preserving or Re-evaluating
From the current tracked Doom config, these behaviors should be considered during migration.

### Likely preserve early
- `SPC` leader model
- `,` localleader model
- Evil-centered editing
- custom `ijkl` movement remaps
- minibuffer movement remaps
- Vertico movement remaps
- Company completion movement remaps
- grep navigation remaps
- magit section navigation remaps
- relative line numbers
- basic Org editing flow
- `org-directory`
- daemon/client workflow

### Likely preserve, but can be implemented later
- org inline-image refresh after babel execution
- Jira export helper via `pandoc -f org -t jira`
- PlantUML output behavior
- DAP Rust template and debugger defaults

### Explicitly reassess, not mandatory for first cut
- Doom theme parity
- Doom font parity
- `twitter`
- RSS stack
- mail stack details
- `my-whisper`
- whether `company` is still the right completion choice
- whether `projectile` should stay vs built-in project tools
- whether `lsp-mode` should stay vs partial `eglot`

## Inventory Work Before Coding Too Much
Before getting deep into implementation, explicitly inventory:

### 1. Actual command flows you use
Write down the commands/flows you use constantly, not just package names.

Examples:
- open file
- switch buffer
- switch project
- find file in project
- grep/search in project
- open magit status
- navigate magit sections
- jump to definition / references
- rename symbol
- fix diagnostics
- format buffer
- split/move windows
- open commit editor with `emacsclient`

### 2. Doom defaults vs explicit custom code
Some of your current behavior comes from Doom defaults, not `.doom.d/config.el`.
Mark each subsystem as:
- explicit custom config
- Doom default
- external dependency
- private/local state
- safe to defer
- safe to drop

### 3. External non-Elisp dependencies
Inventory binaries and services the future config expects.
Examples already visible in repo/config:
- `pandoc`
- `plantuml`
- `gdb` / `rust-gdb`
- mail sync tools if mu4e survives
- language servers
- ripgrep
- any Org-adjacent tooling you rely on in practice

### 4. Secrets/auth strategy
Do this early, not late.
You will likely need a consistent approach for:
- LLM/API keys (`gptel` etc.)
- mail credentials
- anything currently relying on ad hoc file reads or Doom-era assumptions

Preferred direction:
- `auth-source`
- `pass`
- or another intentional credential source

## Migration Phases

### Phase 0: Baseline and inventory
- Produce a daily-use workflow checklist.
- Separate must-have daily flows from secondary workflows.
- Note any current Doom defaults you rely on implicitly.
- Note external dependencies and secrets.

Exit criteria:
- You have a written starter backlog you trust.

### Phase 1: Handcrafted runtime skeleton
- Create the handcrafted config skeleton.
- Keep it isolated from Doom.
- Add package bootstrap and module loading.
- Add explicit launchers/wrappers if needed.

Suggested structure:
```text
emacs/
├── early-init.el
├── init.el
├── lisp/
│   ├── core/
│   ├── ui/
│   ├── editing/
│   ├── project/
│   ├── vcs/
│   ├── lang/
│   └── local/
├── snippets/
└── custom.el
```

Exit criteria:
- Handcrafted Emacs starts cleanly without touching Doom state.

### Phase 2: Daily-driver core
Focus only on the starter backlog.

Bring up, in roughly this order:
- Evil
- leader key + discoverability
- file/buffer/project navigation
- ripgrep/search flow
- magit
- window navigation
- basic Org workflow
- LSP/completion/diagnostics/formatting
- daemon/client/editor integration

Exit criteria:
- You can do normal development work in the handcrafted config.

### Phase 3: Daily use and incremental repair
Use the handcrafted config for real work.

When something is missing:
- write it down
- add only that behavior
- avoid speculative ports

Maintain a running ledger in the plan or a separate checklist.

Suggested living checklist section:
- [ ] Missing keybinding:
- [ ] Missing command flow:
- [ ] Missing language behavior:
- [ ] Missing client/daemon behavior:
- [ ] Missing project/search behavior:

Exit criteria:
- The number of painful missing items is low and shrinking.

### Phase 4: Secondary workflows
Only after the daily-driver core is stable:
- advanced Org customizations
- Jira export helper
- inline image refresh after babel
- DAP/debug templates
- `gptel`
- `my-whisper`
- mail
- RSS
- anything else non-essential to daily coding

Exit criteria:
- Secondary workflows are added intentionally instead of blocking the core migration.

### Phase 5: Doom removal
- Remove Doom from bootstrap and install docs.
- Remove Doom-specific macros and assumptions.
- Stop relying on `.doom.d` and Doom runtime.
- Keep notes for any intentionally changed workflows.

Exit criteria:
- You no longer need Doom for normal work.

## Acceptance Criteria for the First Real Milestone
The handcrafted config is ready for first serious daily use when all of these are true:
- [ ] Evil works.
- [ ] Leader key works.
- [ ] File finding works.
- [ ] Project switching works.
- [ ] Project file search works.
- [ ] Ripgrep/search works.
- [ ] Magit works for normal git tasks.
- [ ] Magit navigation feels acceptable.
- [ ] Window movement/splitting works.
- [ ] Basic Org workflow works.
- [ ] LSP works in your main language(s).
- [ ] Completion/diagnostics/formatting are acceptable.
- [ ] `emacsclient -c` works.
- [ ] Git commit editor works.

## Risks and Mitigations
### Risk: package churn distracts from usable workflow
Mitigation:
- choose packages by UX outcome, not ideology
- do not redesign everything at once

### Risk: side-by-side runtimes interfere with each other
Mitigation:
- keep state, package dirs, and daemon names separate
- use explicit launch commands

### Risk: Doom defaults are mistaken for handcrafted requirements
Mitigation:
- inventory real workflows and explicit customizations first
- don’t port modules just because they were enabled

### Risk: secrets/auth become a late blocker
Mitigation:
- decide early how auth is resolved
- avoid ad hoc file-content hacks

### Risk: completion/LSP/project stack bikeshedding stalls migration
Mitigation:
- accept any stack that gives similar UX first
- optimize later

## Immediate Next Steps
1. Expand the starter backlog with the exact command flows you use most often.
2. Create the handcrafted runtime skeleton in-repo.
3. Implement only the daily-driver core first:
   - Evil
   - leader keys
   - file/project/search workflow
   - magit
   - LSP
   - daemon/client integration
4. Use it daily and add missing pieces as they hurt.
