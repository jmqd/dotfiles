---
description: Specialized commit-message review pass
---
Review the commit message for {{TARGET_NAME}}.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Only perform this review when {{REVIEW_SCOPE}} is a single-commit review such as `commit HEAD`.
If this is not a single-commit review, reply with: No commit-message review applicable.

When applicable, evaluate only the commit message present in the review target's commit metadata, not the diff prose around it.

Focus on whether the commit message is:
- technically objective rather than promotional, theatrical, or grandiose
- concrete about what changed
- clear about why the change was needed, especially when the reason is not obvious from the code alone
- concise rather than padded, repetitive, or overly verbose
- grounded in implementation reality rather than vague claims or broad conclusions
- appropriately scoped to the actual change in the commit

Prefer material findings such as:
- the subject or body overstates impact or certainty
- the message uses vague language where the diff supports a more concrete description
- the message explains what changed but not why
- the message focuses on intent or aspiration while omitting key implementation facts
- the body is longer than needed for the signal it provides
- the wording could mislead future readers about the actual technical behavior or scope

Do not nitpick house style, capitalization, or line length unless it materially hurts technical clarity.
Do not ask for a body if the subject is already sufficient for a small, obvious commit.

For each finding, include:
- severity
- issue
- why it weakens the commit history
- concrete rewrite direction

If there are no material findings, reply with: No material commit-message findings.

Review target:

```text
{{REVIEW_TARGET}}
```
