---
description: Specialized naming review pass
---
Review {{TARGET_NAME}} for naming issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- names that obscure intent
- names that mislead about ownership, lifetime, mutability, or side effects
- inconsistent terminology
- names that are too generic, overloaded, or ambiguous
- places where a better name would reduce the need for comments

Be terse. Prefer naming issues that affect correct understanding or safe use.

For each finding, include:
- severity
- location
- current name or terminology
- why it is misleading or weak
- recommended alternative

If there are no material findings, reply with: No material naming findings.

Review target:

```text
{{REVIEW_TARGET}}
```
