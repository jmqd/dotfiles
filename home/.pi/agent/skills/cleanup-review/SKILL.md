---
name: cleanup-review
description: Find superfluous comments, tests coupled to implementation details, and code that could be simpler, and report them as findings. Use when asked to review, clean up, or tighten the current changes (diff, branch, PR), or a named path or range.
---

# Cleanup review

Report findings in three categories: comments, tests, and simplicity. This is a
review, not an edit pass: change nothing unless the user asks you to apply
findings.

## 1. Pick the scope

Use the scope the user names: a path, a commit, a range, a PR number, or
"everything". Otherwise take the first of these that is non-empty:

1. **Uncommitted work:** `git diff HEAD` plus untracked files
   (`git ls-files --others --exclude-standard`).
2. **The branch, as a PR would show it:** `git diff $(git merge-base HEAD <base>)`,
   where `<base>` is the upstream default branch (`origin/HEAD`, else
   `origin/main` or `origin/master`). Skip this step on the default branch itself.
3. **The last commit:** `git show HEAD`.

For a range, diff its endpoints (`git diff A..B`), so a file added and later
edited counts once. For a PR number, use `gh pr diff <N>`. Say which scope you
used and how many files it covers. A full-repository sweep happens only when
the user asks for one. If you cannot run git, say so and name the files you
reviewed instead; do not guess at changed lines.

Review only lines the scope adds or changes. Read the surrounding code so you
can judge them, but do not report problems in untouched code unless the change
makes them worse.

## 2. Look for the three kinds of finding

### Comments

A comment earns its place when it says what the code cannot: why, an
invariant, a failure contract (errors, panics, safety), or a non-obvious
external constraint. Doc comments on public items are allowed. Flag:

- comments that restate the code (`// increment the counter`)
- narration of the change or history (`// now uses the new API`, `// fixed`)
- commented-out code
- section banners and labels that the structure already shows
- a stale comment that contradicts the code: report this as a bug, not a nit
- a "why" that belongs in the commit message rather than the source

Do not flag a doc comment for being plain, or a comment whose "why" is real but
tersely worded.

### Tests coupled to implementation

A good test fails when behavior breaks and survives any rewrite that keeps the
behavior. Flag tests that:

- assert on internal call order, mock interactions, or private helpers' results
  (using a private helper only to build test setup is fine)
- pin incidental output: log text, exact error wording, formatting, field order
- reach through the public interface to inspect internal state
- copy the implementation's logic to compute the expected value (a tautology)
- check wiring, forwarding, or defaults that cannot plausibly break
- assert only "does not throw" or "is non-empty"
- mock a fast, deterministic dependency that could run for real

For each one, name the behavior it should test instead, and the outermost
fast interface to drive it through. If no behavior is worth testing there,
recommend deleting the test.

### Simplicity

Flag code a maintainer would understand faster in another shape, with the
same behavior:

- abstraction with one implementation or one caller (traits, interfaces,
  factories, wrappers, config for a single case)
- needless indirection: pass-through functions, re-exports, single-use helpers
  that hide one line
- defensive checks for states the types or callers already rule out
- check-then-force (`if x.is_some() { x.unwrap() }`) where destructuring
  proves the fact
- deep nesting or flag variables that early returns or a `match` would flatten
- hand-rolled code the standard library or an existing project helper does
- duplicated logic that one function would serve
- avoidable allocations, copies, or repeated work in compiled code, but only
  on a path that runs often (per item, per request, in a loop); a one-off
  copy is not a finding

Report a simplification only if you can name the simpler form. "This is
complex" without the alternative is not a finding.

## 3. Hold a high bar

- Prefer few, solid findings to many shaky ones. A wrong finding costs more
  than a missed one.
- Check each finding against the code before reporting it: read the callers
  before you call something single-use, and read the test's subject before you
  call an assertion incidental.
- Follow the repository's conventions and AGENTS.md. Do not flag a project
  pattern as a smell.
- Leave correctness and security out of these categories. If you see a real
  bug, list it first under "Bugs", in the same format as other findings.

## 4. Report

Group findings by category, most important first. For each finding give:

- **Where:** `path:line`
- **What:** the problem, in one sentence
- **Fix:** the concrete change: the comment to delete, the behavior to test,
  or the simpler code
- **Confidence:** high or medium. Leave out low-confidence findings, or list
  them under "Unsure" with the reason.

End with the counts per category. If a category has nothing, say "none" so
the reader knows you checked. Then offer to apply the high-confidence fixes.
