---
description: Specialized test-coverage review pass
---
Review {{TARGET_NAME}} for test-coverage gaps and regression-risk blind spots.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on coverage questions such as:
- missing tests for core behavior introduced or changed here
- missing boundary, error-path, or state-transition coverage
- weak assertions that fail to verify the key observable outcome
- missing regression tests for bugs, tricky branches, or recently hardened behavior
- places where characterization tests should be added before refactoring
- important code paths that appear changed without corresponding coverage updates

Rules:
- Stay focused on whether important behavior is covered, not on test style or test architecture.
- Concerns like GIVEN / WHEN / THEN structure, mocks vs fakes, implementation-vs-behavior testing, end-to-end boundaries, fixture quality, and test readability belong primarily in the Behavioral Testing pass.
- Only mention assertion weakness here when it creates a real coverage gap in the observed behavior.
- Prefer the smallest high-value test additions over broad wishlist coverage.

Be terse. For each finding, include:
- priority
- location
- missing or weak coverage
- why the gap matters
- recommended test

If there are no material findings, reply with: No material testing findings.

Review target:

```text
{{REVIEW_TARGET}}
```
