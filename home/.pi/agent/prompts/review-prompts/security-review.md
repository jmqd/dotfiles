---
description: Specialized security review pass
---
Review {{TARGET_NAME}} for security issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Be terse. Report only concrete findings or notable security-relevant absences.

For each finding, include:
- severity
- location
- issue
- exploit or failure mode
- recommended fix

If there are no material findings, reply with: No material security findings.

Review target:

```text
{{REVIEW_TARGET}}
```
