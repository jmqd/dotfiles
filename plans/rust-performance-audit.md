# Rust performance audit: candidate changes

This audit checked the repo's two Rust crates, `pkgs/flow` (CLI) and `projects/omp-phone` (service), against [skills/rust-performance-rules.md](../skills/rust-performance-rules.md). The 114 rules were split across 13 read-only audit agents of about 9 rules each. Their 27 raw findings are deduplicated below into 14 candidate changes.

Nothing here has been measured. Under `PRIN-1`, every item stays a candidate until a benchmark confirms it, so item P1 (a benchmark script) comes first.

## Summary

Both crates are I/O- and subprocess-bound. The rule families for CPU-bound code found nothing to change: `BOUNDS`, `SIMD`, `INLINE`, `LAYOUT` (except one item), `CONC` and `STD`. All the real candidates are algorithm-level or "call it less" changes, mostly in `flow search`, plus one streaming hot path in omp-phone and a few build-time dependency cuts.

| # | Change | Crate | Rules | Path | Confidence | Effort | Behavior change |
|---|---|---|---|---|---|---|---|
| P1 | Benchmark script for search and reindex | flow | MEAS-1, PRIN-1 | process | high | small | no |
| F1 | Push `--repo`/`--path` filters into the zoekt query | flow | PRIN-2/3, MEM-9, IO-4 | per query | medium | small | no (keep Rust post-filter) |
| F2 | Query the running zoekt-webserver instead of spawning the CLI | flow | PRIN-3, MEM-9 | per query | medium | medium | needs `-rpc` flag + fallback |
| F3 | Stream zoekt output and stop at `limit` | flow | IO-2, IO-3 | per query | medium | small | exit-status handling |
| F4 | Run query backends concurrently | flow | MEM-2 | per query | medium | small | error precedence |
| F5 | Remove redundant per-line lowercasing in dirty search; per-file prefilter | flow | PRIN-4, ALLOC-4/5, IO-3/4 | per dirty-file line | high | trivial | no |
| F6 | One `git status` instead of three git calls for dirty files | flow | MEM-9, MEM-2 | per `--include-dirty` query | medium | small | edge cases |
| F7 | Incremental zoekt reindex (seed the temp dir with existing shards) | flow | PRIN-3 | per reindex | high | small | prune deleted repos |
| F8 | Parallelize per-repo reindex work; overlap zoekt and metadata phases | flow | MEM-2, MEM-8, CONC-10 | per reindex | medium | medium | error order |
| F9 | Stop walking into repo working trees during discovery | flow | PRIN-2, MEM-9 | per reindex | medium | small | **yes**: nested repos |
| F10 | FTS5 trigram index for commit search | flow | PRIN-2, MEM-9 | per commit query | low | medium | DB size |
| F11 | Trim per-commit allocations in git log parsing | flow | ALLOC-5, ALLOC-6 | per commit in reindex | low | small | no |
| O1 | Coalesce SSE updates and stop deep-cloning snapshots | omp-phone | PRIN-2/3, ALLOC-5, ALLOC-9 | per update × subscriber | high / medium | trivial / small | no |
| B1 | Build-time dependency cuts (tracing attrs, aws-lc, bundled SQLite) | both | COMPILE-1, COMPILE-2 | build only | high → low | trivial → small | B1b: **yes** (TLS backend) |
| P2 | `[lints.clippy] perf = "warn"` in both crates | both | STD-8 | process | medium | trivial | no |

Suggested order: P1 first, then the cheap and safe changes (F5, F1, O1, B1a, P2). After that, measure before the medium-effort items (F2, F7, F8). F9 and B1b need a product decision first.

---

## Process

### P1. Benchmark script — `MEAS-1`, `PRIN-1`
- **Where:** nothing exists yet. `pkgs/flow` has no `benches/` and no harness. `tests/flow-search-smoke.sh` checks function only.
- **Change:** add `tests/flow-search-bench.sh`, which runs `hyperfine` over fixed realistic queries against the real index:
  - a common term
  - a rare term
  - `--repo`-scoped
  - `--path`-scoped
  - `commits` with a match and with no match
  - `--include-dirty`
  - a back-to-back `flow search reindex` pair (cold, then warm)

  Keep it out of CI, because it depends on the local `~/src`. `hyperfine` is already installed (`home/common.nix:166`).
- **Why first:** nothing below has been measured. This script ranks the other items and confirms each one.

### P2. Clippy perf lints — `STD-8`
- **Where:** `pkgs/flow/Cargo.toml`, `projects/omp-phone/Cargo.toml`. Neither has a `[lints]` table, and no nix check runs clippy.
- **Change:** add `[lints.clippy] perf = "warn"` to both. Optionally run `cargo clippy -- -D clippy::perf` wherever tests already run.
- **Impact:** a regression guard only; no runtime change.

## flow: per-query path (`flow search query` / `code` / `commits`)

### F1. Push scope into zoekt — `PRIN-2`, `PRIN-3`, `MEM-9`, `IO-4`
*Raised independently by 3 groups (Prin, Mem, Io).*
- **Where:** `pkgs/flow/src/search/zoekt.rs:102-130`. The zoekt CLI runs with only the raw query (`["-jsonl", "-index_dir", &index_dir, "--", query]`). Every JSONL line is deserialized, and only then filtered by `file_match.repository != expected_repo` and the path `contains`.
- **Change:** when the filters are set, append `repo:^<regex-escaped display_name>$` and a case-insensitive `file:<regex-escaped path>`, as in `(<query>) repo:^…$`. Keep the Rust post-filters as an exact-semantics guard.
- **Impact:** with `--repo`, zoekt skips the shards of every other repo instead of searching, ranking and base64-encoding matches from them. [INFERENCE] Likely several times faster for common terms on a multi-repo index.
- **Risk:** regex escaping and anchoring. Wrap the user query in parentheses so a top-level `or` stays inside them.

### F2. Use the resident zoekt-webserver — `PRIN-3`, `MEM-9`
*Raised by 2 groups.*
- **Where:** `zoekt.rs:102-104` starts a fresh `zoekt` process for every query, and that process opens and maps every shard. Meanwhile `home/flow-search.nix:26,39` already runs `zoekt-webserver -index <same dir> -listen 127.0.0.1:6070`. flow only uses it for a TCP liveness probe.
- **Change:**
  - Add `-rpc` to the webserver args. [INFERENCE] `/api/` is only mounted with `-rpc`; confirm on the pinned zoekt version.
  - POST `{"Q": …, "Opts": {"MaxDocDisplayCount": limit, …}}` to `/api/search`.
  - Fall back to the CLI when the service is down.
- **Impact:** removes the process spawn and shard load from every query, and lets zoekt stop early at `limit`.
- **Risk:** the response is shaped differently (`Result.Files`). Needs an HTTP client or a hand-written HTTP/1.1 request over `TcpStream`. Reindex replaces the index directory with `remove_dir_all` + `rename` (`zoekt.rs:69-73`), so check that the webserver picks up the new directory.

### F3. Stream zoekt output and stop at `limit` — `IO-2`, `IO-3`
- **Where:** `zoekt.rs:102-120` uses `.output()`, which buffers all of stdout. `String::from_utf8_lossy` then validates the whole buffer before the loop, and the loop usually stops after `limit` matches (default 25).
- **Change:** read stdout through a `Stdio::piped()` + `BufReader::read_until(b'\n')` loop with `serde_json::from_slice`. Kill and wait the child once `limit` is reached.
- **Impact:** peak memory becomes one line. For broad queries this avoids megabytes of buffering. Mostly superseded if F2 lands.
- **Risk:** a killed child exits non-success, so don't report that as a failure. Drain or inherit stderr so the child can't block on a full pipe.

### F4. Run the backends concurrently — `MEM-2`
- **Where:** `pkgs/flow/src/commands/search.rs:152-226`. `execute_query` runs zoekt (subprocess), then SQLite commit search, then dirty search (three git subprocesses), one after another.
- **Change:** run them in `std::thread::scope`, then append results in the current fixed order. Keep the current error precedence.
- **Impact:** latency becomes the slowest backend instead of the sum of all three. [INFERENCE] Tens of ms.

### F5. Dirty search: stop lowercasing per line and per term — `PRIN-4`, `ALLOC-4/5`, `IO-3/4`
*Raised by 4 groups. Verified: terms are already lowercased at `search/mod.rs:43`.*
- **Where:** `pkgs/flow/src/search/dirty.rs:151-156`, which is called once per line at `:74`:
  ```rust
  let normalized_line = line.to_lowercase();
  query_terms.iter().all(|term| normalized_line.contains(&term.to_lowercase()))
  ```
- **Change:**
  1. Use `contains(term.as_str())` and document that terms must already be lowercase.
  2. Lowercase each file once (`contents.to_lowercase()`). Skip the file unless every term occurs somewhere in it, and only run the per-line loop on files that pass.
- **Impact:** allocations drop from lines × (1 + terms) per file to 1 per file. This matters on large untracked files (logs, generated output) that `ls-files --others` picks up.
- **Risk:** none, as long as the per-line verifier stays.

### F6. One git call for the dirty-file set — `MEM-9`, `MEM-2`
- **Where:** `dirty.rs:94-122` spawns `git diff --name-only`, `git diff --cached --name-only` and `git ls-files --others` one after another. Each rescans the index and work tree.
- **Change:** use one `git status --porcelain=v1 -z --untracked-files=all --no-renames` and filter it to the ACMR + `??` set. As a lighter alternative, spawn the three commands at the same time.
- **Impact:** two fewer process spawns and tree scans. [INFERENCE] 10–50 ms.
- **Risk:** status codes must exactly match `--diff-filter=ACMR`, including the T (type change) and unmerged cases.

### F10. Commit search index — `PRIN-2`, `MEM-9` (low confidence; measure first)
*Raised by 2 groups.*
- **Where:** `pkgs/flow/src/search/metadata.rs:131-139` adds one `search_text LIKE '%term%'` per term. An index can't serve a leading wildcard, so rare terms scan every commit.
- **Change:** add an FTS5 table with the `trigram` tokenizer, populated at reindex. It serves `LIKE '%term%'` for terms of 3+ characters; shorter terms fall back to the scan. Check that the bundled SQLite has FTS5 enabled.
- **Impact:** only visible on large histories with rare or no-match terms. Common terms already stop early via `ORDER BY authored_at DESC LIMIT`.

## flow: reindex path (`flow search reindex`, manual)

### F7. Incremental zoekt reindex — `PRIN-3`
- **Where:** `zoekt.rs:31-67`. Each reindex creates an empty temp index dir and runs `zoekt-git-index` for every repo. zoekt's default `-incremental` skip compares against existing shards in the target dir, so it never triggers.
- **Change:** hard-link the current `*.zoekt` shards (and their metadata) into the temp dir before the loop. After the loop, delete shards whose repo is no longer in `repos`. Keep the atomic directory swap.
- **Impact:** [INFERENCE] a reindex after a few commits drops from minutes to roughly the cost of the changed repos.
- **Risk:** pruning must match zoekt's shard naming exactly. Otherwise deleted repos stay searchable.

### F8. Parallelize reindex — `MEM-2`, `MEM-8`, `CONC-10`
*Raised by 2 groups.*
- **Where:**
  - `metadata.rs:71-75`: serial `git log --all --name-only` per repo, each followed by its insert.
  - `commands/search.rs:325-337`: serial `repo_has_head` probes, then the zoekt phase, then the metadata phase.
- **Change:**
  - Collect commits for many repos at once with scoped threads, or rayon with ordered collect. Keep a single SQLite writer, inserting in repo order.
  - Run the HEAD probes in parallel too.
  - Overlap the zoekt and metadata phases; each writes to its own temp location.
  - Either keep the zoekt-git-index loop serial or cap its concurrency (≈ cores/4), because it is already multithreaded.
- **Impact:** [INFERENCE] 2–4× faster reindex wall time with many repos.
- **Risk:** today the first error stops the loop; in parallel, every repo runs and one error is reported. Peak memory and I/O rise.

### F9. Repo discovery: stop at repo roots — `PRIN-2`, `MEM-9` (**behavior change**)
*Raised by 2 groups.*
- **Where:** `pkgs/flow/src/search/repo.rs:79-117`. `WalkDir` skips only the `.git` dir itself and `EXCLUDED_DIRS`, so it still walks every file in every working tree under `~/src`.
- **Change:** when a directory contains `.git`, record it as a repo and call `skip_current_dir()` on the repo root.
- **Impact:** [INFERENCE] goes from every entry under `~/src` (10^5–10^6) to the few hundred directories above repo roots. Seconds per reindex. It also speeds up `--repo` resolution when `repos.json` is missing.
- **Decision needed:** nested repos and submodules inside another repo's tree would no longer be discovered. Choose between dropping them, opting in by config, or handling submodules explicitly.

### F11. Per-commit allocations in git log parsing — `ALLOC-5`, `ALLOC-6` (low)
- **Where:** `metadata.rs:285-330` and `:241`. The code:
  - copies `header` with `.to_owned()`
  - builds `body` by collecting into a Vec and then `join`ing it
  - joins `changed_files` twice and lowercases it twice
  - clones repo-constant `repo_name`/`repo_path` for every commit
- **Change:**
  - Borrow the `Cow` instead of copying `header`.
  - Use `splitn(6, '\x1f')` for the body.
  - Join and lowercase `changed_files` once.
  - Bind `repo_name`/`repo_path` once per repo.
- **Impact:** low single-digit percent at most, because `git log` and SQLite dominate. Do it only if profiling after F8 shows parsing matters.

## omp-phone

### O1. SSE snapshot fan-out — `PRIN-2`, `PRIN-3`, `ALLOC-5`, `ALLOC-9`
*Raised by 3 groups.*
- **Where:** `projects/omp-phone/src/main.rs:127` creates `broadcast::channel(16)`. At `:565-566`, each subscriber runs `app.registry.lock().snapshot(..)` on every queued event. `sessions.rs:85-94` deep-clones every `Session` (up to 200 messages, ≤120 KB of transcript) under the registry mutex. The extension flushes every 250 ms per working session.
- **Change, in steps:**
  - **(a) trivial, high confidence:** coalesce updates. Switch to `watch::Sender`, or drain with `try_recv` after `recv()`, so a slow client gets one fresh snapshot instead of up to 16 stale ones.
  - **(b) small:** stop deep-cloning. Either use a borrowed `Snapshot<'a> { hostname: &str, sessions: Vec<&Session> }` serialized while the lock is held, or store `Arc<Session>` in `Entry`, which needs serde's `rc` feature.
  - **(c) optional:** cache one serialized `Arc<str>` per registry update, so N subscribers share one serialization.
- **Impact:** the only allocation pattern in either crate that grows with streaming rate. Cost ≈ sessions × transcript size × subscribers × 4/s. Fewer redundant frames also save mobile data and battery. Lock hold time drops.
- **Risk:** none for (a); the client already treats every event as a full snapshot. The JSON output of (b) is byte-identical.

## Build time (both crates)

### B1. Dependency cuts — `COMPILE-1`, `COMPILE-2`
- **B1a (high confidence, trivial):** `pkgs/flow/Cargo.toml:28` declares `tracing = "0.1"` with default features. That pulls in `tracing-attributes` → `syn` 2, a second syn alongside the syn 3 used by clap, serde and thiserror. flow never uses `#[instrument]`. Change it to `tracing = { version = "0.1", default-features = false, features = ["std"] }`, then confirm with `cargo tree -i tracing-attributes -e features`.
- **B1b (medium; behavior change):** `projects/omp-phone/Cargo.toml:25` uses `reqwest` with `features = ["rustls"]`. In reqwest 0.13 that enables aws-lc-rs, so `aws-lc-sys` (a large C build) compiles on top of the OpenSSL the crate already links (`ece` backend-openssl, webauthn-rs). Options:
  - `native-tls`, which leaves one crypto stack
  - `rustls-no-provider` + `ring`, which requires installing the provider at startup

  Either option changes the TLS backend and certificate verifier. Re-run the push interop tests.
- **B1c (low; measure first):** `pkgs/flow/Cargo.toml:24` uses `rusqlite` `bundled`, which compiles the SQLite amalgamation. Linking nixpkgs `sqlite` saves time only if `libsqlite3-sys` is on the critical path; check with `cargo build --timings`. The trade-off is losing the pinned SQLite version.

---

## Rules checked with no finding

These were checked and either already satisfied or don't apply. One-line reasons are kept in the audit agents' output.

- **BUILD-1..7:**
  - Both crates are built as release by `buildRustPackage`.
  - omp-phone already sets `lto = "thin"`, `strip = true`.
  - flow has no profile. Adding thin LTO there would only shrink the binary.
  - `target-cpu=native` would break shared nix builds.
- **PROF-1..5, MEAS-2..9:** there is no hot CPU-bound Rust to profile. P1 is the right first step.
- **ALLOC-8/10, LAYOUT-1..9:** no frequently instantiated types and no pointer graphs. Allocator choice doesn't matter at this throughput.
- **INLINE-1..10, BOUNDS-1..9, SIMD-1..5:**
  - There are no inline attributes, no indexed loops, no `get_unchecked`, no `dyn` on hot paths, and all eager `ok_or`/`unwrap_or` arguments are cheap.
  - The `git log -z` byte splits could use `memchr`, but the git subprocess dominates.
- **STD-1..7, IO-1:**
  - HashMaps are tiny with client-supplied keys, so SipHash is correct.
  - `retain` is already used.
  - stdout output is built once and written once.
- **CONC-1..9:**
  - The only atomic already uses `fetch_add(Relaxed)`.
  - parking_lot locks are never held across `.await`.
  - The tokio Mutex is held across `persist().await` only on subscribe and expiry.
  - Side note (cold, not perf): `auth_finish` does synchronous file I/O while holding the `auth` lock inside an async handler (`auth.rs:304`, `main.rs:465-468`).
