---
description: Specialized API review pass
---
Review {{TARGET_NAME}} for API design issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- unclear boundaries
- misuse-prone interfaces
- naming that obscures semantics
- APIs that make invalid states or incorrect use too easy
- missing abstractions or overly leaky abstractions

Be terse. Prefer issues that affect correctness, usability, or long-term evolution.

For each finding, include:
- severity
- location
- issue
- why the API is hard to use correctly
- recommended change

If there are no material findings, reply with: No material API findings.

Review target:

```text
{{REVIEW_TARGET}}
```
