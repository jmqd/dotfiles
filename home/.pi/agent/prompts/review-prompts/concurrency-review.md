---
description: Specialized concurrency review pass
---
Review {{TARGET_NAME}} for concurrency issues and missed parallelization opportunities.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- races, shared-mutable-state hazards, ordering bugs, or missing synchronization
- async sequencing errors, missing awaits, cancellation gaps, or error-propagation issues
- deadlocks, livelocks, starvation, or resource-contention risks
- unnecessary serialization, head-of-line blocking, or avoidable batching barriers
- embarrassingly parallel subproblems that are currently done sequentially
- concurrency changes that would need guardrails such as limits, backpressure, or rate-limit awareness

Be terse. Prefer concrete concurrency bugs or well-supported parallelization opportunities over speculative changes.

For each finding, include:
- impact
- location
- issue
- concrete failure mode or wasted-serialization pattern
- recommended fix and any guardrails needed

If there are no material findings, reply with: No material concurrency findings.

Review target:

```text
{{REVIEW_TARGET}}
```
