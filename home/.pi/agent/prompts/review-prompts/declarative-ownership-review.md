---
description: Specialized declarative-ownership review pass
---
Review {{TARGET_NAME}} for declarative ownership and source-of-truth issues.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- editing generated artifacts, derived outputs, or machine-managed files instead of the declarative source of truth
- imperative mutation of state that appears to be owned by config, schema, build definitions, or other managed inputs
- duplicated configuration or mirrored definitions that can drift because ownership is unclear
- changes that update a downstream artifact without updating the upstream definition that should produce it
- workflows that bypass the managed path and create long-term drift or surprise
- places where comments, naming, file layout, build tooling, tests, or git history suggest a different canonical place should be changed

Rules:
- Prefer source-of-truth fixes over patching generated or synchronized outputs directly.
- Only report ownership issues that are well-supported by the repository structure, naming, surrounding tooling, comments, or obvious generation patterns.
- Do not assume every duplicated file is generated; say when the evidence is inferential.
- If a checked-in generated artifact appears intentionally versioned, focus on whether the generating input changed with it, not on the artifact's existence alone.
- Favor the smallest change that restores clear ownership and reduces drift risk.

For each finding, include:
- confidence
- location
- ownership or source-of-truth issue
- evidence for the likely canonical source
- why drift or manual mutation is risky here
- recommended fix or follow-up

If there are no material findings, reply with: No material declarative-ownership findings.

Review target:

```text
{{REVIEW_TARGET}}
```
