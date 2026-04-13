---
description: Specialized error-handling-and-recovery review pass
---
Review {{TARGET_NAME}} for error-handling and recovery issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- places that should return or propagate an error instead of panicking, crashing, aborting, or silently continuing
- `unwrap`, `expect`, `panic`, fatal exits, unchecked assumptions, or equivalent hard-failure paths that appear avoidable
- `unwrap_or_default()`, broad fallback values, empty catches, ignored results, or silent error swallowing where important signal is lost
- missing error context that would make failures hard to diagnose or act on
- error paths that leave partial state, skip cleanup, or mask whether work completed safely
- recoverable conditions that should surface a structured error flow, retry, or explicit warning instead of disappearing into defaults
- user-facing or operator-facing failures that should be more actionable

Rules:
- Prefer explicit, actionable error flows over crashes, hidden fallback, or lossy defaults when recovery or reporting is practical.
- Do not require defensive handling for impossible states unless the evidence suggests the assumption is actually fragile.
- Do not flag `unwrap_or_default()` or equivalent when there is clearly nothing better to do and the fallback is intentionally harmless; explain why when uncertain.
- Distinguish between truly fatal initialization or invariant failures and routine runtime errors that should be surfaced.
- Favor concrete failure scenarios over abstract advice.

For each finding, include:
- severity
- location
- error-handling issue
- failure mode or lost signal
- why the current handling is too weak, too fatal, or too silent
- recommended fix or follow-up

If there are no material findings, reply with: No material error-handling findings.

Review target:

```text
{{REVIEW_TARGET}}
```
