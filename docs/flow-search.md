# `flow search`

`flow search` is the user-facing CLI for local repository search.

Today it can search three local data sources:

- indexed code and paths via Zoekt
- indexed commit metadata from local git history
- optional live matches from dirty files in a working tree

The implementation is local-only. It builds and reads indexes under a per-user state directory and does not require any remote service.

## What it does

Use `flow search` when you want one command surface for:

- `flow search code ...` for indexed code and path matches
- `flow search commits ...` for indexed commit history matches
- `flow search query ...` to combine code, path, commit, and optionally dirty working tree matches
- `flow search reindex` to rebuild the local indexes
- `flow search status` to inspect configured roots, index state, and managed service status

`flow search query` is the broadest command. By default it searches:

- Zoekt code/path index, if present
- commit metadata index, if present

and can also include dirty working tree matches with `--include-dirty`.

## Current command surface

```bash
flow search query [--repo <name-or-path>] [--path <fragment>] [--limit <n>] \
  [--author <name-or-email>] [--since <date|rfc3339|unix>] \
  [--include-dirty] [--no-code] [--no-commits] <terms...>

flow search code [--repo <name-or-path>] [--path <fragment>] [--limit <n>] <terms...>

flow search commits [--repo <name-or-path>] [--path <fragment>] [--limit <n>] \
  [--author <name-or-email>] [--since <date|rfc3339|unix>] <terms...>

flow search reindex
flow search status
```

Notes on the current flags:

- `--repo` accepts either an indexed repo name/display name or a repo path.
- `--path` is a substring filter, not a glob.
- `--since` currently accepts `YYYY-MM-DD`, RFC3339, or unix seconds.
- `--output json` is available through the normal global `flow` output flag.

## Reindexing is manual today

`flow search` does **not** keep its indexes up to date automatically.

You currently need to run:

```bash
flow search reindex
```

whenever you want indexed code/path results or indexed commit results to reflect new repositories or new committed history.

That command:

- discovers git repos under the configured roots
- skips repos that do not have a `HEAD` commit yet
- rebuilds the Zoekt index from scratch
- rebuilds the commit metadata SQLite database from scratch
- rewrites the repo manifest used for repo selection/status

If the indexes are missing, the current commands behave like this:

- `flow search code ...` fails and tells you to run `flow search reindex`
- `flow search commits ...` fails and tells you to run `flow search reindex`
- `flow search query ...` warns about whichever indexed backend is missing and still uses any remaining enabled backend(s)
- if no backend is usable, `flow search query ...` fails

## `--include-dirty`: scope and limits

`--include-dirty` only applies to `flow search query`.

It searches live file contents from dirty files in exactly one repo:

- the repo selected by `--repo`, or
- if `--repo` is omitted, the repo containing the current working directory

Current behavior/limits:

- it does **not** scan all configured roots
- it only looks at dirty tracked changes plus untracked files
- it does **not** read deleted files or binary files
- it skips files under excluded/generated directories such as `.git`, `.direnv`, `node_modules`, `dist`, `target`, and `result`
- matching is line-based and case-insensitive
- all normalized query terms must appear on the same line for a dirty match to be returned
- `--path` still acts as a substring filter on the relative file path

If you ask for `--include-dirty` outside a git repo and do not provide `--repo`, the command warns and continues with other enabled backends.

`--include-dirty` is an additive live view, not a replacement for reindexing committed history/code.

## `--limit` semantics

The current implementation uses `--limit` as a **per-search-domain** cap, not a global cap across the whole command.

That means:

- `flow search code --limit 10 ...` returns at most 10 indexed code/path matches
- `flow search commits --limit 10 ...` returns at most 10 commit matches
- `flow search query --limit 10 ...` can return more than 10 total results, because each enabled backend gets its own limit

For example, `flow search query --limit 10 ...` can currently include up to:

- 10 Zoekt code/path matches
- 10 commit matches
- 10 dirty matches if `--include-dirty` is enabled

The combined output is grouped by result kind in text mode; JSON output preserves the raw result list.

## Search roots, state, and environment knobs

By default, `flow search`:

- discovers repos under `~/src`
- stores state under `~/.local/share/flow-search`
- expects the managed Zoekt webserver to listen on `127.0.0.1:6070`

Current environment overrides:

- `FLOW_SEARCH_ROOTS`: search roots for repo discovery (path-separated list)
- `FLOW_SEARCH_STATE_DIR`: state directory for indexes/metadata/status files
- `FLOW_SEARCH_ZOEKT_LISTEN`: endpoint reported by `flow search status`
- `FLOW_SEARCH_GIT_BIN`: git executable to use
- `FLOW_SEARCH_ZOEKT_BIN`: zoekt CLI executable to use for searches
- `FLOW_SEARCH_ZOEKT_GIT_INDEX_BIN`: zoekt-git-index executable to use for reindexing

State layout today:

- Zoekt index: `$FLOW_SEARCH_STATE_DIR/zoekt/index` (or `~/.local/share/flow-search/zoekt/index`)
- commit metadata DB: `$FLOW_SEARCH_STATE_DIR/metadata/commits.sqlite`
- repo manifest: `$FLOW_SEARCH_STATE_DIR/metadata/repos.json`
- search state: `$FLOW_SEARCH_STATE_DIR/state.json`

## Home Manager service behavior: Linux vs Darwin

This repo ships Home Manager management for a long-running `zoekt-webserver` process.

### Linux

On Linux, Home Manager declares a user `systemd` service:

- service name: `flow-search-zoekt`
- starts `zoekt-webserver`
- restarts on failure
- is wanted by `default.target`

### Darwin

On macOS/Darwin, Home Manager declares a `launchd` agent:

- agent name: `flow-search-zoekt`
- starts `zoekt-webserver`
- `RunAtLoad = true`
- `KeepAlive = true`
- writes stdout/stderr logs to `/tmp/flow-search-zoekt.log` and `/tmp/flow-search-zoekt.err.log`

Both variants point the webserver at the same local Zoekt index directory and listen on `127.0.0.1:6070` by default.

## Is the long-running Zoekt service required?

For the current shipped `flow search` CLI behavior, the long-running `zoekt-webserver` is **not required**.

The command implementation:

- uses the `zoekt` CLI directly for indexed searches
- uses `zoekt-git-index` directly for reindexing
- only checks the configured listen address for observability in `flow search status`

So today the service is best understood as:

- managed by Home Manager
- observable from `flow search status`
- available for other workflows/future integration
- **not** required for `flow search code`, `flow search commits`, `flow search query`, or `flow search reindex`

## Current limitations worth knowing

These are current shipped limitations, not proposal text:

- reindexing is manual
- indexed search freshness depends on the last successful `flow search reindex`
- `query` merges backend results but does not rank/deduplicate them across backends
- `--limit` is per backend/domain rather than global
- dirty search is single-repo only and line-based
- commit search is based on the local metadata database, not live git history reads at query time

## Examples

```bash
# rebuild indexes after adding repos or new commits
flow search reindex

# inspect configured roots, state paths, and whether the managed service is reachable
flow search status

# search indexed code/path matches in one repo
flow search code createFlowSearchDirs --repo dotfiles

# search commits by subject/body/author/changed-files text
flow search commits review --author jordan --since 2026-01-01

# search code + commits together, plus live dirty matches from the current repo
flow search query search backend --include-dirty

# machine-readable output
flow --output json search query hello --repo dotfiles
```
