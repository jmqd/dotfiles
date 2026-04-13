---
description: Specialized behavioral-testing review pass
---
Review {{TARGET_NAME}} for test-design quality.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on whether tests in the review target, or tests that should naturally accompany the change, are:
- behavior-focused rather than implementation-focused
- as functional or integrated as practical for the risk and boundary being tested
- organized so the scenario, action, and outcome read clearly, preferably in GIVEN / WHEN / THEN terms
- using realistic fake data, fixtures, builders, or in-memory adapters instead of mocks where that better preserves real behavior
- asserting durable outcomes rather than symptoms of the current implementation
- clear about end-to-end behavior where end-to-end coverage is the right confidence boundary

Also look for other high-quality test traits such as:
- deterministic behavior without fragile timing, randomness, or ordering assumptions
- strong failure diagnostics when the test breaks
- focused fixtures that make intent obvious
- meaningful boundary and failure-path behavior coverage at the right layer
- avoiding broad snapshots or incidental log/string assertions when direct behavior assertions would be stronger

Rules:
- Stay focused on test quality and test design, not general missing coverage; broad missing-test findings belong mostly in the Testing pass.
- Prefer behavior, contracts, and observable outcomes over internal calls, private helpers, intermediate state, or exact implementation sequence.
- Do not demand end-to-end tests when a narrower layer is the correct boundary; only recommend higher-level tests when they would materially increase confidence.
- Only flag GIVEN / WHEN / THEN issues when the current naming or structure makes the test materially harder to understand.
- If recommending fewer mocks, say what fake or fixture should replace them and why it would be more trustworthy.
- Prefer the smallest concrete change that improves confidence without rewriting the whole suite.

For each finding, include:
- priority
- location
- test-quality issue
- why it weakens confidence
- concrete rewrite direction

If there are no material findings, reply with: No material behavioral-testing findings.

Review target:

```text
{{REVIEW_TARGET}}
```
