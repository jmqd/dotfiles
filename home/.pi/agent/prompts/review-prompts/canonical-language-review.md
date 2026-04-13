---
description: Specialized canonical-language-and-tooling review pass
---
Review {{TARGET_NAME}} for cases where non-trivial implementation logic is drifting into the wrong substrate instead of the repository's canonical general-purpose implementation language and tooling.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on cases such as:
- shell scripts that are growing beyond thin glue into real program logic
- ad hoc scripting in Bash or similar for parsing, branching, retries, state management, data transformation, or error handling that would be safer in the repo's main implementation language
- repeated command orchestration that should likely become a typed task, CLI command, xtask, internal tool, or library function
- logic that is becoming hard to test, hard to refactor, or hard to make portable because it lives in the wrong layer
- places where the surrounding repo clearly has an established implementation language and tooling stack, but this change adds more logic in a weaker substrate

Strong examples include:
- in a Rust repo, longer Bash glue that should likely move into Rust or an xtask
- in a TypeScript repo, growing shell or one-off JS snippets that should likely become a typed TS command or helper
- in a Go repo, workflow logic that should likely become a small Go command instead of a complex script

Rules:
- Only report this when the repository's canonical implementation language is reasonably clear from the surrounding code, tooling, file layout, or existing patterns.
- Do not flag short, thin wrappers that mostly invoke one or two commands with minimal logic.
- Do not treat shell, Nix, Make, or config as wrong when they are the natural source of truth for environment wiring, declarative config, build entrypoints, or tiny glue.
- Prefer concrete signs of script growth: significant branching, parsing, loops, retries, state handling, complex quoting, duplicated command sequences, or non-trivial error handling.
- Recommend the most natural native landing place when possible: xtask, internal CLI subcommand, library helper, typed task runner, or existing app/module boundary.
- If the repo's canonical language is mixed or unclear, report no findings unless the maintainability benefit is very well-supported.

For each finding, include:
- confidence
- location
- substrate mismatch or script-growth issue
- evidence for the likely canonical implementation language or native tooling path
- why the current approach will age poorly
- concrete migration direction

If there are no material findings, reply with: No material canonical-language findings.

Review target:

```text
{{REVIEW_TARGET}}
```
