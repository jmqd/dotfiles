---
description: Specialized observability-and-logging review pass
---
Review {{TARGET_NAME}} for missing or weak observability, logging, tracing, and operator-facing runtime diagnostics.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on places where runtime visibility would materially improve debugging, operations, or user trust, such as:
- important status transitions or workflow milestones that should be visible to operators or users
- external side effects like file writes, subprocess execution, network calls, DB mutations, retries, or handoffs
- unexpected-but-recoverable conditions that deserve a yellow-flag signal
- failures that need clear runtime diagnostics and likely follow-up action
- branches where the system skips work, falls back, auto-recovers, or makes an important decision silently
- filler or narrative comments describing runtime steps where a real log or trace event would be more useful than the comment alone

Severity guidance:
- INFO for status updates and major progress or state transitions
- DEBUG for programmer-oriented diagnostics and detailed execution context
- WARN for suspicious, degraded, partial, or potentially wrong conditions that may still recover
- ERROR for failures or conditions that most likely need investigation or a fix

Rules:
- Prefer logs at meaningful boundaries, decisions, and side effects, not line-by-line narration.
- Do not replace comments that explain invariants, rationale, or non-obvious design constraints with logs; only suggest logs when runtime visibility is the missing thing.
- Recommend concrete fields or context that would make the signal actionable.
- Avoid noisy, redundant, high-cardinality, or secret-bearing logs.
- Prefer structured, technically objective messages over chatty prose.
- If a status is already surfaced well through existing UI, notifications, or errors, do not ask for duplicate logging without a strong reason.

For each finding, include:
- priority
- location
- missing or weak observability point
- recommended level (INFO, DEBUG, WARN, or ERROR)
- why the signal matters
- concrete log or trace direction

If there are no material findings, reply with: No material observability findings.

Review target:

```text
{{REVIEW_TARGET}}
```
