---
description: Ask Oracle GPT-5.5 Pro through the Oracle CLI and fold the answer into this Codex thread
argument-hint: PROMPT
---

Use the Oracle CLI as an advisory second-model consult for this request:

$ARGUMENTS

Route through `oracle` with ChatGPT browser mode and GPT-5.5 Pro:

```sh
oracle --engine browser --model gpt-5.5-pro -p "<standalone prompt>"
```

Workflow:

1. Turn the user request into a standalone Oracle prompt. Include only task-relevant repo context, constraints, commands, and exact errors that Oracle needs.
2. If files are needed, choose the smallest useful file set. Never attach secrets, `.env` files, tokens, credentials, browser profiles, or unrelated whole-repo dumps.
3. For file-backed consults, preview first:

```sh
oracle --engine browser --model gpt-5.5-pro \
  --dry-run summary --files-report \
  -p "<standalone prompt>" \
  --file "<glob-or-path>"
```

4. If the preview is reasonable, run Oracle. Use a short slug when the prompt is likely to run for a while:

```sh
oracle --engine browser --model gpt-5.5-pro \
  --slug "<short-slug>" \
  -p "<standalone prompt>" \
  --file "<glob-or-path>"
```

5. If Oracle detaches, times out, or reports a stored session, do not restart the same request first. Reattach:

```sh
oracle status --hours 72
oracle session <id-or-slug> --render
```

6. Present Oracle's answer under `Oracle result`. Add a separate `Codex note` only when useful, and clearly distinguish Codex's interpretation from Oracle's output.

Use API mode only if the user explicitly asks for it or explicitly approves API usage, since it can spend API credits.
