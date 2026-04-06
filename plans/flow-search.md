# Flow Search Plan

## Decision
Add a new `flow search` command that presents a single CLI surface over multiple local search backends:
- **Zoekt** for code, file, and path search
- a **git metadata backend** for commit/history-oriented search
- a **live dirty-state overlay** for the current repo or an explicitly selected repo

The search system will run **locally on the laptop**, be exposed only via a **CLI**, and use a **localhost-only Home Manager-managed service** for the Zoekt portion.

## Goals
1. Give humans and agents one stable command for repo search: `flow search ...`.
2. Search both code and git history metadata without forcing one tool to do everything.
3. Keep the service private and local-only.
4. Work on both macOS and Linux via Home Manager.
5. Support manual reindexing without requiring always-on background indexing jobs.
6. Return results in formats suitable for both humans and agents.

## Non-Goals
- Do not expose a public HTTP API.
- Do not build a custom pi extension first; agents can call the CLI directly.
- Do not attempt globally indexed dirty-working-tree search across all repos under `~/src`.
- Do not add health checks or flake checks for the search service in the first pass.
- Do not build a perfect symbol index in v1.

## Scope Assumptions
- Search root: `~/src`
- Search service host: laptop only
- Search service visibility: `localhost` only
- Index refresh: manual only for v1
- Dirty state: supported only for the current repo or an explicit `--repo`
- Output modes: text and JSON

## High-Level Architecture

```text
flow search
  ├── query planner / argument parsing
  ├── zoekt backend
  │    ├── localhost zoekt service
  │    └── zoekt indexes for repos under ~/src
  ├── git metadata backend
  │    └── local metadata index / query store
  └── dirty-state overlay
       └── live search against current repo or --repo target
```

## Why This Architecture
Zoekt is a strong fit for code search, but not for all git metadata. Trying to make a single engine handle:
- file contents
- file paths
- functions/types
- commit messages
- changed files
- authors
- dirty working tree content

would either underdeliver or become awkward.

A hybrid backend keeps the user-facing surface simple:
- one CLI
- one output format family
- multiple specialized data sources underneath

## Search Domains

### 1. Code / Path Search
Handled by Zoekt.

Primary use cases:
- find code mentioning a symbol or term
- find files by path/name
- find likely function/type definitions by name-ish search
- search across many repos under `~/src`

### 2. Git Metadata Search
Handled by a separate metadata backend.

Primary use cases:
- search commit messages
- filter/search by author
- find commits touching a file
- search commit bodies / subjects
- later: search refs/tags/branches if useful

### 3. Dirty Working Tree Search
Handled live, not indexed.

Primary use cases:
- include current unstaged/staged changes in investigations
- help agents search the repo they are actively modifying
- avoid the cost and ambiguity of globally indexing mutable state

Constraint:
- only supported for the current repo or an explicit `--repo`

## Proposed CLI Shape

### Top-Level Commands
```bash
flow search query <terms...>
flow search code <terms...>
flow search commits <terms...>
flow search reindex
flow search status
```

### Example Queries
```bash
flow search query zoekt
flow search code createBashTool
flow search commits "review scope"
flow search query codex --repo dotfiles --output json
flow search query "search backend" --repo ~/src/dotfiles --include-dirty
flow search reindex
flow search status
```

### Recommended Flags
```text
--repo <name|path>      Limit search to one repo
--path <path-fragment>  Narrow by path
--author <author>       Filter commit results
--since <date>          Filter commit results
--limit <n>             Max results per domain
--output <text|json>    Human or machine-readable output
--include-dirty         Include live dirty-state overlay
--no-code               Skip Zoekt-backed code search
--no-commits            Skip git metadata search
```

### Output Design
#### Text
Group by result type:
- Code matches
- Path matches
- Commit matches
- Dirty working tree matches

This avoids pretending that code-search scores and commit-search scores are directly comparable.

#### JSON
Return a unified typed result list, e.g.:
```json
{
  "results": [
    {
      "kind": "code",
      "repo": "dotfiles",
      "path": "pkgs/flow/src/main.rs",
      "line": 42,
      "snippet": "..."
    },
    {
      "kind": "commit",
      "repo": "dotfiles",
      "commit": "1aadee1",
      "author": "Jordan McQueen",
      "subject": "pi/review: harden commit scope parsing"
    },
    {
      "kind": "dirty",
      "repo": "dotfiles",
      "path": "bin/hive",
      "line": 12,
      "snippet": "..."
    }
  ]
}
```

## Repo Discovery
Search roots are configured explicitly, starting with:
- `~/src`

Discovery behavior:
- recursively find non-bare git repos
- ignore `.git` internals
- likely ignore transient worktrees unless explicitly selected

### Default Path Exclusions
Initial exclusions should likely include common generated/build directories:
- `.git`
- `.direnv`
- `node_modules`
- `dist`
- `target`
- `result`
- other obvious generated/output trees as needed

## Index / State Layout
Use a flow-owned local data directory, e.g.:

```text
~/.local/share/flow-search/
├── zoekt/
│   ├── index/
│   └── config.json
└── metadata/
    ├── commits.sqlite
    └── repos.json
```

Rationale:
- keeps search state tied to `flow`
- avoids scattering separate ad hoc cache/state directories
- easy to back up, inspect, or wipe intentionally

## Zoekt Service Model
### Service Characteristics
- Home Manager-managed user service
- localhost-only binding
- stable port
- no public exposure
- no timer required for indexing in v1

### Responsibilities
- serve code/path search queries from local indexes
- stay simple and private
- be queryable by `flow search`

### Platforms
- macOS: launchd user agent via Home Manager
- Linux: systemd user service via Home Manager

## Git Metadata Backend
### Responsibilities
Maintain a local queryable store of commit metadata for repos under `~/src`.

### Initial Indexed Fields
V1 should prioritize:
- repo name/path
- commit SHA
- author name/email
- authored/committed date
- subject
- body
- changed files

### Query Types
V1 should support at least:
- commit message/body search
- author filtering
- changed-file search
- repo filtering
- date filtering if easy

### Backend Choice
A local SQLite database is the likely simplest fit:
- easy to update manually
- easy to query deterministically
- easy to package conceptually inside `flow`

## Dirty-State Overlay
### Design
Dirty working tree search should be live and repo-local, not part of the global index.

### Activation
Only when:
- `cwd` is inside a repo, or
- `--repo` is provided

### Sources
Likely live data sources:
- `git diff`
- `git diff --cached`
- `git ls-files --others --exclude-standard`
- possibly `rg` over the working tree where appropriate

### Why limit scope
Searching dirty state across all repos under `~/src` would be slow, ambiguous, and operationally noisy. Repo-local overlay is the useful case.

## Reindex Model
### V1 policy
Manual only.

### Command
```bash
flow search reindex
```

### Expected behavior
- discover repos under `~/src`
- rebuild/update Zoekt indexes
- rebuild/update git metadata index
- do not touch dirty-state overlay because it is live-only

## Status / Diagnostics
### Command
```bash
flow search status
```

### Useful information to report
- configured roots
- index directory paths
- service endpoint
- number of indexed repos
- last reindex time
- index/backend availability

This should be enough for humans and agents to understand whether search is usable.

## Agent Usage Model
Agents should use the CLI directly via shell calls.

Expected patterns:
- human-friendly output:
  - `flow search query <terms>`
- agent-friendly output:
  - `flow search query <terms> --output json`

This keeps the first integration simple and agent-agnostic.

## Flow Integration
`flow` currently exposes only a small command surface. `search` would become a substantial new subcommand family.

Likely additions:
- `Commands::Search(...)`
- nested clap subcommands for `query`, `code`, `commits`, `reindex`, `status`
- typed result structs and output renderers for text/json

The search feature should follow the same project conventions already used elsewhere in `flow`:
- typed clap command structure
- explicit dispatch in `main.rs`
- logs on stderr
- command output on stdout
- text/json output modes

## Suggested Phases

### Phase 1: CLI and config skeleton
- add `flow search` clap structure
- define config model for roots/index locations/service endpoint
- define result types and text/json rendering
- add `status` and `reindex` skeletons

Exit criteria:
- `flow search --help` is stable and coherent

### Phase 2: Zoekt-backed code search
- package/run local Zoekt service via Home Manager
- implement repo discovery under `~/src`
- implement `flow search code`
- implement `flow search query` with Zoekt-only results first

Exit criteria:
- code/path search works across indexed repos

### Phase 3: Git metadata backend
- create/update local metadata index
- implement `flow search commits`
- merge commit results into `flow search query`

Exit criteria:
- users can search commit history and changed-file metadata locally

### Phase 4: Dirty-state overlay
- detect current repo / honor `--repo`
- add live dirty-state matches to `query`
- keep dirty results clearly labeled as live, not indexed

Exit criteria:
- current repo dirty changes show up when explicitly requested or repo-local search is used

### Phase 5: filters and polish
- repo/path/author/date filters
- better result ranking/grouping
- stronger truncation/formatting for agent consumption
- refine exclusions/discovery behavior

Exit criteria:
- search is useful enough for regular human and agent investigations

## Open Questions
1. Which Zoekt packaging path is best for Home Manager on macOS and Linux in this repo?
2. Should path-only matches be a separate subcommand or folded into `query`/`code`?
3. Should dirty-state overlay be on by default for repo-local searches, or always require `--include-dirty`?
4. Should worktrees under `~/src` be indexed by default or skipped?
5. Is SQLite sufficient for metadata search long-term, or just the right v1 tradeoff?

## Recommendation Summary
Build `flow search` as the product, not Zoekt as the product.

That means:
- one CLI surface
- specialized local backends underneath
- localhost-only service for Zoekt
- manual indexing
- repo-local dirty-state overlay
- text/json outputs suitable for humans and agents

This gives a practical first version without overcommitting to any single search engine.
