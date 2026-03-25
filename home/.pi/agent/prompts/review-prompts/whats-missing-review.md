---
description: Specialized whats-missing review pass
---
Review {{TARGET_NAME}} for important omissions.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on things that are missing but plausibly expected from the surrounding evidence, such as:
- missing error handling, validation, or fallback behavior
- missing tests for behavior that appears important or fragile
- missing API/RPC operations or fields needed for a cohesive surface
- missing edge-case handling suggested by adjacent code paths
- missing user guidance, diagnostics, or status where the workflow implies they matter
- missing feature wiring where nearby patterns strongly suggest it should exist

Only report omissions that are well-supported by the code, tests, comments, names, neighboring APIs, or obvious symmetry in the existing design. Do not turn this into a speculative wishlist.

For each finding, include:
- location
- missing thing
- evidence that it is expected
- why the omission matters
- recommended addition or follow-up

If there are no material findings, reply with: No material whats-missing findings.

Review target:

```text
{{REVIEW_TARGET}}
```
