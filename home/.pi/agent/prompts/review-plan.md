---
description: Reconcile aggregated review findings into a coherent change plan
---
You are turning an aggregated code review into an implementation plan for {{TARGET_NAME}}.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Review target:

```text
{{REVIEW_TARGET}}
```

Aggregated review report:

{{AGGREGATED_REVIEW}}

Produce a terse Markdown plan with these sections:
1. Recommended change strategy
2. Conflict reconciliation
3. Dependency edges / prerequisites
4. Ordered change plan
5. Suggested commit boundaries
6. Verification order
7. Deferred or optional improvements

Rules:
- Reconcile conflicting or competing suggestions into one coherent plan.
- Prefer correctness and safety first, then tests, then API/logic changes, then refactors, then readability/docs polish.
- Prefer test-first or characterization-test-first sequencing where practical.
- Order changes to minimize churn and rework.
- Favor plans that minimize repeated edits to the same files.
- Call out dependency edges explicitly when one change should happen before another.
- Prefer boundary-first or interface-first changes when they reduce downstream churn.
- Separate behavior changes from refactors where practical.
- Naming, readability, and documentation improvements should usually follow functional and API stabilization unless they are prerequisites for safe or correct changes.
- Suggest commit groupings that keep reviewable units small, coherent, and reversible.
- If findings are weakly supported or speculative, defer them instead of forcing them into the plan.
- If some findings should be dropped, merged, or deferred, say so explicitly.
