---
description: Specialized maintainability review pass
---
Review {{TARGET_NAME}} for maintainability issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- change amplification
- brittle assumptions
- poor separation of concerns
- upgrade or migration hazards
- code that will be costly to evolve safely

Be terse. Prefer durable improvements over stylistic tweaks.

If there are no material findings, reply with: No material maintainability findings.

Review target:

```text
{{REVIEW_TARGET}}
```
