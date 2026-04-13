---
description: Specialized history-informed review pass
---
Review {{TARGET_NAME}} for omissions or inconsistencies suggested by git history for the same files or subsystem.

Review scope: {{REVIEW_SCOPE}}
Scope details: {{SCOPE_DESCRIPTION}}

Git history context:

```text
{{GIT_HISTORY_CONTEXT}}
```

Focus on history-backed gaps only, such as:
- files that are usually updated together in this area but are not updated here
- tests, docs, config, migrations, or wiring that prior commits in this area repeatedly changed alongside similar code
- sibling modules, platform variants, or mirrored paths that history suggests should stay in sync
- assumptions or intended behavior stated in commit messages that this change appears to leave incomplete

Rules:
- Prefer repeated patterns or a direct precedent in the same files or subsystem.
- Prefer recent, local history over broad repo-wide coincidence.
- Ignore mechanical churn like version bumps, formatting sweeps, lockfile-only changes, and mass renames unless directly relevant.
- Do not repeat a generic whats-missing finding unless the git history materially strengthens the case.
- If the history is sparse, noisy, or not clearly relevant, report no findings.

For each finding, include:
- confidence
- location or likely missing file or area
- suspected missing piece
- historical evidence (commit subject(s) and touched-file pattern)
- why that precedent applies here
- recommended follow-up

If there are no material findings, reply with: No material history-informed findings.

Review target:

```text
{{REVIEW_TARGET}}
```
