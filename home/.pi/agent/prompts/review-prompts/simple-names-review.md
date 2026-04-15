---
description: Specialized simple-names review pass
---
Review {{TARGET_NAME}} for overly complex or unclear names.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Focus on:
- function or method names that are not verbs or clear verb phrases
- variable, field, parameter, constant, and type names that are not nouns or clear noun phrases
- names that use obscure idioms, metaphors, analogies, or unnecessarily fancy words when simple words would be clearer
- names that are too long, too compound, or too dense to understand at a glance
- inconsistent naming for the same concept
- abbreviations that are not industry-standard and understandable even by non-experts

Heuristics:
- Prefer simple, common, concrete words over clever or abstract wording.
- Functions should usually be verbs. Variables should usually be nouns.
- Three or more underscore-separated parts is suspicious.
- Even two underscore-separated parts can be suspicious if a simpler name would do.
- Apply the same suspicion to three or more subwords in camelCase or PascalCase.
- Treat these as heuristics, not automatic failures.
- Do not flag standard, widely understood abbreviations.
- Test names are allowed to be long and descriptive when that improves clarity and coverage-report usefulness. Do not flag test names for length or number of subwords alone.

Be terse. Prefer only material simplification opportunities, not churn.
- For test-name findings, only report them when they are actually misleading, inconsistent, or hard to understand.

For each finding, include:
- severity
- location
- current name or term
- why it is too complex, indirect, or inconsistent
- simpler recommended alternative

If there are no material findings, reply with: No material simple-name findings.

Review target:

```text
{{REVIEW_TARGET}}
```
