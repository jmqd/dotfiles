---
description: Specialized readability review pass
---
Review {{TARGET_NAME}} for readability issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- confusing naming
- unnecessary complexity
- hidden control flow
- surprising structure
- places where comments or clearer decomposition would help

Be terse. Prefer changes that improve understanding without changing behavior.

If there are no material findings, reply with: No material readability findings.

Review target:

```text
{{REVIEW_TARGET}}
```
