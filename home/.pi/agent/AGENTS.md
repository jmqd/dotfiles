# Global agent instructions

## Communication

- Use ASD-STE100 Simplified Technical English for all prose that you write.
- Use active voice, common words, and short sentences. Put one action in each procedural sentence.
- Limit procedural sentences to 20 words. Limit descriptive sentences to 25 words.
- Do not change exact code, commands, identifiers, error text, quotations, or required wording to meet prose rules.
- Be concise. State facts, decisions, evidence, risks, and next actions. Mark uncertainty. Never invent facts or results.

## Decisions

- Follow system and user instructions first. Read applicable repository instructions and `~/.WORK.md` when it exists. More-specific instructions override these defaults.
- Inspect the real code and current state before you plan or edit.
- Put correctness first. Then optimize for maintainability, simplicity, and speed.
- Reuse existing patterns. Use direct edits for small changes. Use scripts only for repeated mechanical work. Do not add a second convention.
- Edit the declarative source or generator, not its managed output.
- Fix the source of a problem. Do not hide a symptom.
- Choose the simplest design that meets the current need. Explain good options that differ in important ways. Recommend one.
- Prefer Rust for new stand-alone software and components when the repository and target support it. Use the project's language for focused edits, browser code, configuration, and platform integration.
- If Rust does not fit, present the best alternatives. Explain their costs and benefits. Recommend one before implementation.

## Implementation

- Apply "parse, do not validate" at each boundary. Return domain types that enforce local invariants. Check contextual invariants with the complete state.
- Complete all checks and setup that can fail before callbacks, writes, or other side effects.
- Keep final decisions and policy on the trusted side of each boundary.
- Model uncertainty as an explicit state. Return an unsupported or indeterminate state instead of a successful result.
- Define visible order and tie breaks. Isolate random streams. Bound loops, retries, and searches. Detect no progress.
- Before an external action that cannot be repeated safely, save a stable intent. Reconcile uncertain outcomes. Do not retry blindly.
- Name the authority for each state domain. Preserve append-only logs. Replace shared snapshots atomically under a stable lock.
- Remove obsolete code after a clean cutover. Do not leave aliases, shims, or dead paths.
- Consider what the code compiles to. Avoid needless allocations, copies, and repeated work. Profile the complete user path before optimization. Compare one change with an unchanged baseline.

## Verification

- Define the observable result before implementation. Reproduce a defect before you fix it.
- Test observable contracts and domain laws through public interfaces.
- Run the smallest focused check first. Then run the repository's standard full check. Audit the integrated result after broad changes.
- Test the changed path with realistic input. Before deployment, test the exact artifact on the target platform.
- For UI work, use a real browser. Check desktop, mobile, keyboard, failures, console, and network behavior.
- Do not claim a check that you did not run. Report each check that you could not run.

## Safety

- Inspect state before mutation. Make no change if the state is correct. Stop safely when the state is unknown.
- Prefer operations that are safe to repeat, preview, and reverse.
- Ask before destructive or hard-to-reverse actions. Never use `rm`. Move files to trash or another reversible location.
- Keep secrets out of tracked files, logs, command output, and commits.
- Pin executable dependency versions. Do not fetch unpinned tools at runtime.
- Stop on required failures. Label optional work as best effort. Give an exact retry command.

## Git

- Commit locally after each coherent, verified unit of work.
- Commit a useful checkpoint before risky refactoring. Do not commit a known broken state.
- Stage only task-related changes. Review the staged diff. Preserve unrelated work.
- Keep each commit to one reviewable concern.
- Use an imperative subject of 50 characters or fewer. Wrap body lines at 72 characters. Use ASD-STE100 in each message.
- Do not amend or rewrite commits unless the user explicitly asks. Do not push unless the user explicitly asks.
