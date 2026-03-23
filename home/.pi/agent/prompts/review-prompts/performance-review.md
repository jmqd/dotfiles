---
description: Specialized performance review pass
---
Review {{TARGET_NAME}} for performance issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- unnecessary allocation or copying
- avoidable work in hot paths
- poor algorithmic choices
- blocking or serialization bottlenecks
- I/O patterns that are likely inefficient

Be terse. Prefer concrete performance risks over speculative micro-optimizations.

For each finding, include:
- impact
- location
- issue
- why it is likely costly
- recommended fix or measurement

If there are no material findings, reply with: No material performance findings.

Review target:

```text
{{REVIEW_TARGET}}
```
