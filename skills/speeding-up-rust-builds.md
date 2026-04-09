# Speeding Up Rust Builds

A practical, actionable guide for reducing Rust compile times. Intended for use by humans and AI agents alike — each section is self-contained and can be tackled independently.

Sources: [matklad][1], [corrode][2], [nnethercote perf book][3], [Feldera][4], [Bevy][5], [Rust blog][6].

[1]: https://matklad.github.io/2021/09/04/fast-rust-builds.html
[2]: https://corrode.dev/blog/tips-for-faster-rust-compile-times/
[3]: https://nnethercote.github.io/perf-book/compile-times.html
[4]: https://www.feldera.com/blog/cutting-down-rust-compile-times-from-30-to-2-minutes-with-one-thousand-crates
[5]: https://bevy.org/learn/quick-start/getting-started/setup/
[6]: https://blog.rust-lang.org/2025/09/10/rust-compiler-performance-survey-2025-results/

---

## 0. Measure First

Before changing anything, establish a baseline. Optimizing without data is guessing.

### `cargo build --timings`

Generates an HTML Gantt chart showing per-crate compile time, parallelism, and critical path. Look for:

- **Long sequential chains** — crates that block everything behind them.
- **Red/waiting segments** — crates idle because a dependency hasn't finished.
- **One dominant crate** — a single crate taking longer than everything else.

### `cargo check`

If you don't need a runnable binary yet, prefer `cargo check` while iterating:

```sh
cargo check
cargo check --tests
```

It skips final codegen and linking, which usually makes edit/compile loops much faster than `cargo build`.

### `cargo llvm-lines`

Shows which functions produce the most LLVM IR. Generic functions instantiated many times are the usual culprits.

```sh
cargo install cargo-llvm-lines
cargo llvm-lines --lib --release -p <crate>
```

### `-Zmacro-stats`

Profiles how much code each macro generates (nightly only):

```sh
RUSTFLAGS="-Zmacro-stats" cargo +nightly build
```

### `-Ztime-passes`

Shows time spent in each compiler phase (nightly only):

```sh
RUSTFLAGS="-Ztime-passes" cargo +nightly build
```

### `-Zself-profile`

Generates a trace you can view in Chrome's profiler or with `summarize`/`flamegraph`:

```sh
cargo install --git https://github.com/rust-lang/measureme --branch stable summarize
cargo +nightly rustc -p <crate> -- -Zself-profile
summarize summarize <crate-name-and-pid>.mm_profdata
```

Install `flamegraph` or `crox` from the same `rust-lang/measureme` repo if you want SVG flame graphs or Chrome trace output instead of a text summary.

---

## 1. Linker

Linking is often the single biggest bottleneck. If your timings show link time dominating, switching linkers is usually a high-impact, low-effort change.

### Linux: use `mold` if linking is still the bottleneck

Add to your `flake.nix` devShell:

```nix
packages = [ pkgs.mold pkgs.clang ];
```

(See also: `sudo apt install mold` or `brew install mold`)

`.cargo/config.toml`:

```toml
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]

[target.aarch64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

If `mold` isn't available, `lld` is a good fallback. On modern `x86_64-unknown-linux-gnu` stable toolchains, Rust already defaults to `lld`, so switching to `lld` may do nothing. Benchmark against `mold` only if your timings still show link time dominating.

### macOS: keep the default linker unless measurement says otherwise

Current macOS toolchains already use a fast system linker (`ld-prime`). Don't cargo-cult `lld`/`mold` here; first confirm that linking is actually your bottleneck with `cargo build --timings`.

### Windows: use `lld`

Install LLVM so `lld-link` is available on `PATH`, then:

```toml
[target.x86_64-pc-windows-msvc]
linker = "lld-link"
```

---

## 2. Dev Profile Tuning

These go in your workspace root `Cargo.toml`.

```toml
[profile.dev]
opt-level = 0          # Don't optimize your own code in dev
debug = "line-tables-only"  # Enough for backtraces, much cheaper than full debuginfo
incremental = true     # Default, but be explicit
codegen-units = 256    # Maximum parallelism for LLVM codegen

[profile.dev.package."*"]
opt-level = 3          # Fully optimize dependencies (they rarely change)

[profile.dev.build-override]
opt-level = 3          # Optimize proc macros and build scripts — they run at compile time
```

On modern macOS Cargo versions, `split-debuginfo = "unpacked"` is already the default when debuginfo is enabled. Only set it explicitly if you need to support older toolchains or want the setting documented in-repo.

---

## 3. Dependency Hygiene

### Remove unused dependencies

```sh
cargo install cargo-machete
cargo machete
# or
cargo install cargo-shear
cargo shear
```

### Find duplicate dependency versions

```sh
cargo tree --duplicates
```

Multiple versions of the same crate (e.g., two versions of `syn`) mean double the compile work. Consolidate with `cargo update` or version pinning in `[patch]`.

### Disable default features

Most dependencies ship with features you don't need. Always start with:

```toml
some-dep = { version = "1", default-features = false, features = ["only-what-you-need"] }
```

### Consider lighter alternatives

| Heavy | Lighter Alternative | Notes |
|-------|-------------------|-------|
| `serde` + `serde_derive` | `miniserde`, `nanoserde` | If you only need basic (de)serialization |
| `reqwest` | `ureq` | Sync-only, much smaller dep tree |
| `clap` (derive) | `lexopt`, `pico-args` | If you have simple CLI args |
| `regex` | `memchr`, manual parsing | If you're matching simple patterns |
| `chrono` | `time` | Smaller, no C dependency |

### Audit with `cargo build --timings`

Look at the HTML output. If a dependency you barely use is in the critical path, consider removing or replacing it.

---

## 4. Proc Macro Cost

Proc macros (`#[derive(...)]`, `#[async_trait]`, `sqlx::query!()`, etc.) are expensive because:

1. They must compile fully before any dependent crate can start.
2. They generate code that the compiler then has to process.
3. They break pipellined compilation — `rustc` can't compute metadata until the macro runs.

### Measure macro cost

```sh
RUSTFLAGS="-Zmacro-stats" cargo +nightly build
```

### Mitigate

- **Push proc-macro-heavy deps toward leaf crates**, not foundational ones. If `serde/derive` is enabled on a core crate, every downstream crate waits for `syn`.
- **Feature-gate expensive derives** so they only compile when needed:

  ```toml
  [dependencies]
  serde = { version = "1", optional = true }

  [features]
  serde = ["dep:serde", "serde/derive"]
  ```

- **Optimize proc macro compilation** with `[profile.dev.build-override] opt-level = 3`.
- **Consider `watt`** for ahead-of-time proc macro compilation to Wasm (experimental).
- **Watch for feature flags** that sneakily enable proc macros downstream.

---

## 5. Monomorphization Bloat

Generic functions are compiled once per concrete type they're instantiated with. A function like `fn process<T: Serialize>(val: T)` used with 50 types = 50 copies of the LLVM IR.

### Diagnose

```sh
cargo llvm-lines --lib -p <crate>
```

### Fix: the inner-function pattern

Wrap generic entry points around non-generic implementations:

```rust
pub fn read<P: AsRef<Path>>(path: P) -> io::Result<Vec<u8>> {
    fn inner(path: &Path) -> io::Result<Vec<u8>> {
        std::fs::read(path)
    }
    inner(path.as_ref())
}
```

The generic part is a trivial shim; the real work is monomorphized only once.

### Fix: `dyn Trait` at crate boundaries

Where performance isn't critical (startup code, config parsing, error paths), prefer dynamic dispatch:

```rust
// Instead of:
fn log_error(handler: impl Fn(&str)) { ... }

// Use:
fn log_error(handler: &dyn Fn(&str)) { ... }
```

### Fix: reduce combinator chains

Replace highly-instantiated method chains like `Option::map`, `Result::map_err` with explicit `match`:

```rust
// This instantiates the closure type for map_err:
let x = foo().map_err(|e| MyError::from(e))?;

// This doesn't:
let x = match foo() {
    Ok(v) => v,
    Err(e) => return Err(MyError::from(e)),
};
```

Only worth doing for hot paths identified by `cargo llvm-lines`.

---

## 6. Crate Graph Design

### Aim for wide, not deep

```
Bad:  A -> B -> C -> D -> E     (sequential, no parallelism)

Good:     +- B -+
         /       \
        A --> C --> F            (parallel compilation of B, C, D)
         \       /
          +- D -+
```

### Split large crates

If a single crate dominates your `--timings` chart, consider splitting it. Common split boundaries:

- By feature/domain (e.g., separate destination drivers into their own crates)
- By stability (rarely-changing code in one crate, frequently-changing in another)
- Generated code into separate crates (Feldera saw 10-15x improvement splitting 100K lines of generated Rust into ~1000 crates)

### Use `cargo-hakari` for large workspaces

In a workspace, the same dependency can be compiled multiple times with different feature sets. `cargo-hakari` creates a "workspace hack" crate that unifies features:

```sh
cargo install cargo-hakari
cargo hakari init
cargo hakari generate
```

Can reduce build times by up to 50% in large workspaces.

---

## 7. Test Compilation

### Combine integration tests

Each file in `tests/` produces a separate binary. Each binary links independently. With N test files, you pay the link cost N times.

```
tests/
  main.rs        # Single entry point
  mod_a.rs
  mod_b.rs
```

```rust
// tests/main.rs
mod mod_a;
mod mod_b;
```

### Use `cargo-nextest`

Parallel test execution (not compilation), but significantly faster overall:

```sh
cargo install cargo-nextest
cargo nextest run
```

### Gate slow tests

```rust
#[test]
fn slow_integration_test() {
    if std::env::var("RUN_SLOW_TESTS").is_err() {
        return;
    }
    // ...
}
```

---

## 8. CI-Specific Optimizations

### Disable incremental compilation

Incremental adds tracking overhead. CI builds from scratch, so this is pure waste:

```yaml
env:
  CARGO_INCREMENTAL: 0
```

### Disable debuginfo

```yaml
env:
  CARGO_PROFILE_DEV_DEBUG: 0
  CARGO_PROFILE_DEV_STRIP: debuginfo
```

### Cache dependencies, not your code

Use [Swatinem/rust-cache](https://github.com/Swatinem/rust-cache):

```yaml
- uses: Swatinem/rust-cache@v2
```

Don't cache the entire `./target` — your own crates change every build, so caching them wastes upload/download time and can cause stale artifacts.

### Deny warnings via env, not code

```yaml
env:
  RUSTFLAGS: "-D warnings"
```

Avoid `#![deny(warnings)]` in source — it causes cache invalidation when the warning set changes between compiler versions.

### Separate compile from test execution

```yaml
- run: cargo test --no-run --locked
- run: cargo test
```

Isolates where time is actually spent.

### Consider whether `--all-features` is needed on every job

If you have expensive optional features, run a feature matrix on a subset of CI jobs instead of `--all-features` on every job.

---

## 9. IDE & Local Environment

### Separate `rust-analyzer` target directory

Prevent `rust-analyzer` and `cargo build` from invalidating each other's caches:

In VS Code `settings.json`:

```json
{
  "rust-analyzer.cargo.targetDir": true
}
```

Reported up to 9x improvement in some cases.

### macOS: disable Gatekeeper for dev tools

```sh
sudo spctl developer-mode enable-terminal
```

Then add your terminal to System Settings > Privacy & Security > Developer Tools. Prevents macOS from re-checking every binary on every build.

### Close unrelated projects

Each open project runs its own `rust-analyzer` instance. Multiple instances compete for CPU and memory.

---

## 10. Advanced / Experimental

### Cranelift backend

An alternative codegen backend that's faster than LLVM but produces slower binaries. Good for dev builds:

```sh
rustup component add rustc-codegen-cranelift-preview --toolchain nightly
CARGO_PROFILE_DEV_CODEGEN_BACKEND=cranelift cargo +nightly build -Zcodegen-backend
```

### Parallel compiler frontend

```sh
RUSTFLAGS="-Z threads=8" cargo +nightly build
```

Parallelizes the compiler frontend. Claims up to 50% speedup depending on code structure.

### `sccache` for multi-project environments

Add to your `flake.nix` devShell:

```nix
packages = [ pkgs.sccache ];
```

(See also: `cargo install sccache`)

Then set:

```sh
export RUSTC_WRAPPER=sccache
```

Caches compiled crates across projects. Most useful if you work on multiple Rust projects sharing dependencies.

### Dynamic linking in dev

Compile a heavy dependency as a dylib to skip relinking it on every rebuild:

```sh
cargo install cargo-add-dynamic
cargo add-dynamic <dep>
```

Bevy uses this pattern — it's the single most impactful change for projects with one dominant dependency.

### In-memory build directory

On Linux, mount a `tmpfs` for `target/`:

```sh
mount -t tmpfs -o size=4G tmpfs ./target
```

Eliminates disk I/O as a bottleneck. Not persistent across reboots — treat as ephemeral.

---

## Quick Reference: Where to Start

1. **Use `cargo check`** when you don't need a binary yet.
2. **Run `cargo build --timings`** — understand your specific bottlenecks.
3. **Switch linker on Linux** (`mold` if linking still dominates; modern stable may already be on `lld`).
4. **Tune dev profile** — `debug`, `build-override`.
5. **Audit deps** — `cargo machete`, `cargo tree --duplicates`.
6. **Profile macros** — `-Zmacro-stats`, then feature-gate or relocate.
7. **Profile generics** — `cargo llvm-lines`, then apply inner-function pattern.
8. **Restructure crate graph** — split large crates, consider `cargo-hakari`.
