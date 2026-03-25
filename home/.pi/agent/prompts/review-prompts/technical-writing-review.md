---
description: Specialized technical-writing review pass
---
Review the technical writing in {{TARGET_NAME}}.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Only evaluate prose that is actually present, such as:
- comments
- docs/READMEs/plans/prompts
- help text
- user-facing explanatory strings

Focus on:
- clarity over cleverness
- simple, direct wording suited to readers who may not be native speakers
- short, readable sentences
- brevity and fast time-to-answer
- avoiding unnecessary jargon, buzzwords, and theatrical phrasing
- scannable headings, lists, and instructions
- consistent terminology and capitalization where inconsistency harms comprehension
- places where the prose makes the reader work harder than necessary

Do not report code-structure, API, or behavioral issues unless the prose itself is misleading about them.

For each finding, include:
- location
- issue
- why it hurts comprehension or task completion
- a concrete rewrite direction

If there are no material findings, reply with: No material technical-writing findings.

Review target:

```text
{{REVIEW_TARGET}}
```
