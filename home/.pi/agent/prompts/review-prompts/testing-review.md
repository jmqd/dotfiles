---
description: Specialized testing review pass
---
Review {{TARGET_NAME}} from a testing perspective.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- missing tests
- weak assertions
- untested edge cases
- regression risk
- places where tests should be added before refactoring

Be terse. For each finding, include:
- priority
- location
- missing or weak test coverage
- recommended test

If there are no material findings, reply with: No material testing findings.

Review target:

```text
{{REVIEW_TARGET}}
```
