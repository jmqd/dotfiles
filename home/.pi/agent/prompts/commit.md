---
description: Stage relevant changes and write concise factual commit(s)
argument-hint: [FILES="<paths>"] [WHY="<context>"] [REFS="<refs>"]
---

Use `~/.gitmessage` as the starting point for commit structure. Follow these constraints; they override any conflicting guidance:

- Create an appropriate number of commits, with a strong preference for one commit when the change is coherent.
- Keep each commit subject at 50 characters or less.
- Wrap body text at 72 columns.
- Write in a declarative, concise, objective style.
- Avoid fluff, hype, broad claims, invented references, and LLM attribution.
- Use Markdown-compatible plain text when a body is useful.

First inspect the current repository state with `git status --short` and determine the relevant change set from the current conversation and recent work. If `FILES=` is provided, restrict the commit to those paths. Otherwise, stage only dirty files that are clearly related to the task at hand. Do not add unrelated files, do not sweep up the whole worktree, and do not amend unless explicitly asked. If there are multiple plausible change groups and the right subset is not clear, stop and ask.

Before committing, review the diff for every file you plan to stage. Then write a simple, factual, data-driven commit message. Keep the body to 1-3 short paragraphs in the normal case. Start with high-level context that helps a reader understand why the change was made, then briefly cover what changed. Explain how only when the implementation needs explanation, using concrete pointers and details. Add links to relevant research material, tests, issue IDs, benchmark numbers, commands, file paths, or source material at the end only when they materially support the change and are actually available. If `WHY=` or `REFS=` is supplied, use them only if they are accurate and helpful.

After the commit, report the commit hash, subject, staged files, and any dirty files intentionally left out.
