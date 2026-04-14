---
description: Stage relevant changes and write a factual commit
argument-hint: [FILES="<paths>"] [WHY="<context>"] [REFS="<refs>"]
---

Use `~/.gitmessage` as the starting point for commit structure and tone. Follow its constraints unless there is a strong reason not to: imperative subject, subject line at 50 characters or less, concise body, and concrete references only when they are real and useful.

First inspect the current repository state with `git status --short` and determine the relevant change set from the current conversation and recent work. If `FILES=` is provided, restrict the commit to those paths. Otherwise, stage only dirty files that are clearly related to the task at hand. Do not add unrelated files, do not sweep up the whole worktree, and do not amend unless explicitly asked. If there are multiple plausible change groups and the right subset is not clear, stop and ask.

Before committing, review the diff for every file you plan to stage. Then create a simple, factual, data-driven commit message. Keep the body to 1-3 short paragraphs in the normal case. Start with the big-picture why when it is not obvious, then cover the concrete what and any important how details. Add references, tests, issue IDs, benchmark numbers, commands, file paths, or source material only when they materially support the change and are actually available. Do not add hype, attribution, broad claims, or invented references. If `WHY=` or `REFS=` is supplied, use them only if they are accurate and helpful.

After the commit, report the commit hash, subject, staged files, and any dirty files intentionally left out.
