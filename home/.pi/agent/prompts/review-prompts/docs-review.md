---
description: Specialized documentation review pass
---
Review {{TARGET_NAME}} for documentation and communicative clarity issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- missing or misleading comments
- undocumented invariants or assumptions
- missing API usage guidance
- places where tests or names imply intent that the docs do not explain
- places where future maintainers are likely to misunderstand behavior

Be terse. Prefer documentation gaps that affect safe or correct use.

If there are no material findings, reply with: No material documentation findings.

Review target:

```text
{{REVIEW_TARGET}}
```
