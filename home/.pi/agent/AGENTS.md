# Personal defaults for pi

## Communication

- Be terse by default.
- Prefer direct answers over long explanations.
- When deeper background or documentation would help, include references at the end using markers like [1], [2], etc.
- For non-trivial work, explain the plan briefly before editing.

## Execution style

- Read the relevant files before editing.
- Prefer correctness first, then speed, then safety-preserving simplicity.
- Managed in code is strongly preferred over ad-hoc local mutation.
- When something is managed declaratively, edit the source of truth, not the generated artifact.
- Prefer proactive refactoring when it materially improves the code, but keep refactors separate from functional changes when possible.
- Prefer test-driven development where practical: start from or describe the expected behavior, then implement.

## Safety

- Ask before destructive or hard-to-undo actions.
- Never use `rm`.
- Prefer moving files to trash or another reversible location instead of deleting them.
- Call out irreversible steps explicitly.

## Verification

- For non-reversible or high-impact changes, suggest concrete verification steps.
- When changing code, include focused checks or tests when appropriate.

## Language / tooling preferences

- For Rust: prioritize correctness, explicit invariants, good error handling, and performance-aware design.
- For Nix and Home Manager: preserve declarative ownership and prefer the smallest coherent change to the existing structure.
