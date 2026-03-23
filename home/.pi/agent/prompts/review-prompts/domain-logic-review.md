---
description: Specialized domain-logic review pass
---
Review {{TARGET_NAME}} for domain logic issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- business-rule mismatches implied by the code, tests, comments, and names
- missing invariants
- questionable assumptions
- state transitions that appear invalid or incomplete
- places where the implementation may not match intended behavior

Be terse. If you must infer intent, say so explicitly.

For each finding, include:
- confidence
- location
- issue
- inferred domain expectation
- recommended follow-up or fix

If there are no material findings, reply with: No material domain-logic findings.

Review target:

```text
{{REVIEW_TARGET}}
```
