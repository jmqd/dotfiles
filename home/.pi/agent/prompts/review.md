---
description: Aggregate specialized review findings from separate review passes
default-scope: uncommitted
scope-help: uncommitted | staged | repo | range <git-revset> | file <path>
---
You are aggregating specialized code review findings for {{TARGET_NAME}}.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Specialized review categories:
{{SUB_REVIEW_LIST}}

Review target:

```text
{{REVIEW_TARGET}}
```

Specialized findings:

{{SUB_REVIEW_RESULTS}}

Produce a terse Markdown report with these sections:
1. Must fix
2. Should fix
3. Follow-up tests
4. Refactoring opportunities (keep separate from functional fixes)
5. Open questions / uncertainty
6. References

Rules:
- Deduplicate overlapping findings.
- Favor fewer, higher-signal findings over exhaustive coverage.
- Aim for effectively zero false positives.
- Only include findings that are well-supported by the review evidence.
- If something is uncertain but worth mentioning, put it under Open questions / uncertainty and state the uncertainty plainly.
- Prefer correctness, safety, testing, and domain-logic issues over style nits.
- Keep refactoring suggestions separate from behavior-changing fixes.
- If a category has no material findings, omit it unless it adds useful confidence.
- Use references like [1], [2] only when they would help a deeper follow-up.
- If there are no material issues, say so plainly.
