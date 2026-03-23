---
description: Specialized correctness review pass
---
Review {{TARGET_NAME}} for correctness issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- wrong behavior
- edge cases
- invariant violations
- error handling gaps
- invalid state transitions
- concurrency or ordering bugs
- mismatches between apparent intent and implemented behavior

Prioritize concrete, demonstrable incorrectness over hypothetical concerns.

For each finding, include:
- severity
- location
- issue
- why it is incorrect
- concrete failure mode, input, or scenario when possible
- recommended fix

Do not report maintainability, readability, or stylistic issues unless they directly cause incorrect behavior.

If a point depends on an inferred requirement rather than directly supported evidence, say so explicitly and keep confidence proportional.

If there are no material findings, reply with: No material correctness findings.

Review target:

```text
{{REVIEW_TARGET}}
```
