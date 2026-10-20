# Rust Performance Engineering Rules

Rules for making Rust programs fast. Each rule cites its source. Numbers are what the authors measured on their own hardware, so treat them as orders of magnitude, not promises. Items marked ⏳ depend on the Rust version or toolchain; re-check them before relying on them.

Companion to [speeding-up-rust-builds.md](speeding-up-rust-builds.md), which covers compile times in depth.

## How to use this file

- **Rule IDs are stable.** Cite a rule as `ALLOC-4` or `CONC-2` in reviews, findings and commit messages. When you add a rule, append it to its section with the next number. Never renumber existing rules.
- **Families:**
  - `PRIN`: principles
  - `MEAS`: measurement and benchmarking
  - `BUILD`: build configuration
  - `PROF`: profiling
  - `ALLOC`: heap allocation
  - `LAYOUT`: data layout and type sizes
  - `INLINE`: inlining, generics and codegen
  - `BOUNDS`: bounds checks and loops
  - `SIMD`: SIMD and vectorization
  - `MEM`: memory hierarchy and latency
  - `STD`: hashing and std choices
  - `IO`: I/O and text
  - `CONC`: concurrency
  - `COMPILE`: compile times
- **Applying a rule to code needs evidence.** `PRIN-1` and `MEAS-*` apply to every other rule: a finding is a candidate until a profile or benchmark shows the code is hot.
- **Code audits:** `PRIN`, `MEAS` and `PROF` describe process. The other families point to concrete code patterns.

## Sources

### Primary (the three to read first)

| Source | Author | Why it matters |
|---|---|---|
| *The Rust Performance Book* [1] and the "How to speed up the Rust compiler" blog series [2–7] | Nicholas Nethercote | The standard reference. Terse, practical, and each technique links to a real rustc PR. Nethercote wrote Cachegrind and DHAT, and his series made rustc "at least 2-3x faster … in many cases" [2]. |
| matklad.github.io [8–17] | Alex Kladov (matklad) | Author of rust-analyzer, now at TigerBeetle. Explains *why* the compiler does or doesn't optimize: inlining, separate compilation, vectorization, layout. Also covers build times and allocation strategy. |
| burntsushi.net [18, 19] | Andrew Gallant (BurntSushi) | Author of ripgrep, `regex`, `memchr` and `aho-corasick`. Shows algorithm-level performance work end to end, with very careful benchmark methodology. |

### Additional (excellent, more specialized)

| Source | Author | Focus |
|---|---|---|
| Bounds-check article [20], cookbook repo [21], "State of SIMD in Rust in 2025" [22] | Sergey "Shnatsel" Davidoff | Removing bounds checks safely; choosing a SIMD strategy. Reproducible with `cargo asm` and `hyperfine`. |
| curiouscoding.nl [23, 24] | Ragnar Groot Koerkamp (with František Kmječ) | Memory-hierarchy-aware algorithm design in Rust. Took a sorted search from 1150 ns to 27 ns per query. |
| *Rust Atomics and Locks* (free online) [25–28] | Mara Bos | What concurrent code costs at the hardware level: cache lines, CAS, orderings on x86 vs ARM, lock design. A book rather than a blog, but its hardware chapter is unmatched. |

---

## 0. Core principles

1. **PRIN-1** **Measure first, optimize only hot code.** Optimized code is more complex and harder to maintain, so the effort is only worth it where profiles show time is spent [1 §General Tips].
2. **PRIN-2** **Algorithms and data structures beat micro-tuning.** The biggest wins usually come from those changes [1 §General Tips]. ripgrep beats grep because of *what it searches for* (literals, rare bytes), not tighter loops [18].
3. **PRIN-3** **For a hot function, either make it faster or call it less** [1 §General Tips][2].
4. **PRIN-4** **Removing silly slowdowns is easier than inventing clever speedups.** "*not doing unclever things* is often as important as *doing clever things*" [4]. One example: a logging function that did work even when logging was off cost up to 15% [4].
5. **PRIN-5** **Small wins compound.** "It's rare that a single micro-optimization is a big deal, but dozens and dozens of them are. Persistence is key" [2].
6. **PRIN-6** **Explain a result before you believe it.** The popular explanation is often wrong. Inlining slowdowns get blamed on the i-cache, but matklad traced one to extra register saves and an extra `cmp` in the hot loop [9]. Cross-check one tool against another [9].
7. **PRIN-7** **Expect most attempts to fail, and revert the ones that don't pay.** Nethercote "had more failures than successes" in 2022 [6]. Drop changes whose gain does not justify the extra code [6]. A change that wins on benchmarks but regresses real users gets reverted [5].
8. **PRIN-8** **Write comments that cite measurements.** Optimized code has a non-obvious shape. A comment like "99% of the time this vector has 0 or 1 elements" explains it [1 §General Tips].

## 1. Measurement and benchmarking

1. **MEAS-1** **Benchmark the user's actual problem with realistic workloads.** Microbenchmarks are fine in moderation. Mediocre benchmarking is far better than none [1 §Benchmarking].
2. **MEAS-2** **To compare two nearly identical builds, use instruction counts.** Noise is "±0.1% vs ±3%" for wall time, and instruction-count changes rarely disagree with wall time in that setting. Don't use instruction counts to compare unrelated programs [2].
3. **MEAS-3** **Keep an untouched baseline next to your change** (two clones or two binaries) and compare them on many benchmarks [4]. Judge results per benchmark, not by one aggregate, because many wins show up only on a few inputs [2][4]. If you must aggregate, use the geometric mean, which is "very crude", and show per-benchmark diffs as well [19].
4. **MEAS-4** **Keep the compiler from deleting the work.** Make inputs runtime-overridable (from CLI or stdin) and print a hash or other summary of the outputs. This beats sprinkling `black_box`, and the hash also catches wrong results [17][20].
5. **MEAS-5** **Make runs reproducible.** Pin the CPU frequency, disable SMT if you can, take 5 runs and report the median plus spread [23]. Alternatively, warm the cache with 3 runs, then report mean ± stddev over 10 [18].
6. **MEAS-6** **Sweep input sizes from L1 up to RAM, and avoid only testing powers of two.** Power-of-two sizes cause cache-associativity sawtooth artifacts. Sample sizes like 2^i, 1.25·2^i, 1.5·2^i and 1.75·2^i [24][23].
7. **MEAS-7** **Make the tools you compare do the same visible work** (line counting, Unicode mode). Isolate one variable at a time, e.g. `rg` vs `rg --mmap`. Check sensitivity to the environment: a VM penalized mmap [18].
8. **MEAS-8** **Use the right harness.** Options include Criterion, Divan, hyperfine for whole binaries, Bencher for CI, and Gungraun for instruction counts [1 §Benchmarking].
9. **MEAS-9** **Guard against regressions continuously.** Weekly triage of merged changes cost Nethercote about 45 minutes a week [2–5]. Use `dhat-rs` heap tests to pin allocation counts [1 §Heap Allocations], and static size assertions on hot types (§5).

## 2. Build configuration

1. **BUILD-1** **Benchmark release builds only.** Dev builds are commonly 10–100× slower [1 §Build Configuration].
2. **BUILD-2** **For maximum speed, try these one at a time and benchmark each:**
   - `codegen-units = 1`
   - `lto = "fat"` (or `"thin"`); LTO can give "10-20% or more"
   - `panic = "abort"`
   - an alternative global allocator (jemalloc via `tikv-jemallocator`, or `mimalloc`)
   - PGO via `cargo-pgo`, which can give 10% or more

   [1 §Build Configuration]
3. **BUILD-3** **Target-specific instructions:**
   - `-C target-cpu=native` when the binary runs only on the build machine [1 §Build Configuration].
   - `-C target-cpu=x86-64-v3` (AVX2) for fleets you control [22].
   - Function multiversioning for binaries you distribute. The default x86-64 baseline is SSE2 only [22].
   - Some optimizations depend on target features. Without `native`, the search code got no cmov and S-trees were "much slower" [24].
4. **BUILD-4** **For profiling builds:**
   - `debug = "line-tables-only"` in `[profile.release]`
   - `-C force-frame-pointers=yes` for usable stacks
   - `-C symbol-mangling-version=v0` if demangling breaks

   [1 §Profiling]
5. **BUILD-5** ⏳ **Use a fast linker.** lld has been the default linker for `x86_64-unknown-linux-gnu` since Rust 1.90; mold or wild are other options. The system linker on macOS is already fast [1 §Build Configuration].
6. **BUILD-6** **For dev-build speed:**
   - Set `debug = false` or `"line-tables-only"` in `[profile.dev]`, which can be 20–40% faster.
   - On nightly, try `-Zthreads=8` or the Cranelift backend.

   [1 §Build Configuration]
7. **BUILD-7** If unsure, use `cargo-wizard`. Profile settings only take effect in the workspace root [1 §Build Configuration].

## 3. Profiling workflow

1. **PROF-1** **Rough order of usefulness:**
   1. instruction counts (Cachegrind/Callgrind)
   2. allocations (DHAT)
   3. ad hoc counts
   4. memory (DHAT/Massif)
   5. LLVM IR lines (`cargo llvm-lines`)
   6. memcpy
   7. cycles (perf)

   [2]
2. **PROF-2** **Use more than one profiler and chain them.** "Every time I did a new type of profiling, I found new things to improve" [2]. For example, Cachegrind shows `malloc` and `memcpy` are hot, then DHAT finds the call sites [2].
3. **PROF-3** **Sampling profilers:**
   - `perf` with Hotspot or Firefox Profiler on Linux
   - `samply` on any OS
   - Instruments on macOS
   - VTune or μProf
   - `cargo flamegraph`

   For causal "what if this were faster" questions, use Coz [1 §Profiling].
4. **PROF-4** **Ad hoc profiling.** When you know *what* is hot but not *why*, add `eprintln!("TAG {}", value)` lines, then run `grep TAG log | counts` (add `-w`/`-i` to weight by value). Prefix every line with a tag. Read the raw log too: a run of increasing numbers exposed quadratic behavior. The code is temporary, so crude is fine [3].
5. **PROF-5** **Read the machine code for small hot kernels.** Use Compiler Explorer or `cargo-show-asm`. Put `#[inline(never)]` on the target function so it shows up as its own symbol [1 §Machine Code][20]. To see whether a function was inlined in Cachegrind output, check its first and last lines: inlined functions have no counts there [1 §Inlining].

## 4. Heap allocation

Allocation is "moderately expensive": a global lock, data-structure bookkeeping, sometimes a syscall. Small allocations are not necessarily cheaper than large ones [1 §Heap Allocations]. In rustc, cutting about 10 allocations per million instructions gave roughly 1% [1 §Heap Allocations].

1. **ALLOC-1** **Find hot allocation sites with DHAT** before changing code [1 §Heap Allocations].
2. **ALLOC-2** **Pre-size collections.** Use `Vec::with_capacity`, `reserve` and `String::with_capacity`. Implement `size_hint` or `ExactSizeIterator` on your own iterators so that `collect`/`extend` can pre-size [1 §Heap Allocations, §Iterators].
3. **ALLOC-3** **Measure the length distribution at hot `push` sites** (eprintln + counts) and pick a type to match [1 §Heap Allocations]:
   - many short vectors → `SmallVec<[T; N]>`
   - known maximum length → `ArrayVec`
   - known long vectors → `with_capacity`
4. **ALLOC-4** **Reuse "workhorse" buffers.** Hoist the `Vec`/`String` out of the loop and `clear()` it on each iteration. Pass `&mut Vec<T>` in instead of returning a new `Vec`. Use `read_line` into one reused `String` instead of `lines()`, which allocates for every line [1 §Heap Allocations].
5. **ALLOC-5** **Avoid needless owning.** Use `Cow` for mixed borrowed and owned data. Store references instead of `to_owned()` when profiling justifies the lifetimes. Use `clone_from` to reuse an existing allocation. Remove stale `clone()` calls. Avoid `format!` when a literal works [1 §Heap Allocations].
6. **ALLOC-6** **Don't collect an iterator just to iterate it again.** Return `impl Iterator` instead, and use `extend` rather than collect-then-append [1 §Iterators].
7. **ALLOC-7** **Allocate in bulk.** Use bump or arena allocation for objects with the same lifetime. Count first, then allocate exactly, then fill. Build structures of unknown size in scratch space and copy them once [11]. For servers and databases, consider allocating everything at startup with fixed capacity limits [16].
8. **ALLOC-8** **Intern repeated strings** into one buffer and pass `u32` IDs. But "allocators are pretty fast", and a cleverer trie interner turned out "slower, larger and way more complex" [14].
9. **ALLOC-9** **`Rc`/`Arc` on rarely shared values adds allocations.** `make_mut` gives clone-on-write semantics [1 §Heap Allocations, §Standard Library Types].
10. **ALLOC-10** **Try an alternative allocator** before rewriting code. Large wins have been seen in practice, and results vary by platform [1 §Build Configuration].

## 5. Data layout and type sizes

1. **LAYOUT-1** **Shrink frequently instantiated types.** Smaller types mean less memory traffic and cache pressure. Values over 128 bytes are copied with `memcpy` [1 §Type Sizes].
2. **LAYOUT-2** **Inspect layouts** with `RUSTFLAGS=-Zprint-type-sizes cargo +nightly build --release` or `top-type-sizes` [1 §Type Sizes].
3. **LAYOUT-3** **Box the rare, oversized enum variant.** Use `u32`/`u16` indices instead of `usize`. Use `Box<[T]>` (2 words) for vectors that won't change, or `ThinVec` (1 word) for vectors that are usually empty [1 §Type Sizes].
4. **LAYOUT-4** **Pin hot type sizes with a static assertion,** gated by `cfg(target_arch)` [1 §Type Sizes].
5. **LAYOUT-5** **Prefer `u32` indices into arrays over pointers, `Box` trees or `Rc` graphs.** Each saves 4 bytes on 64-bit, and the savings add up across every structure. Use newtype indices so an index can't be used with the wrong array. Represent a child list as `(start, count)` into shared storage [15][11]. matklad would "default to indexes for code where speed matters" even before profiling [15].
6. **LAYOUT-6** **Keep hot data inline.** A plain struct of fields is "completely transparent" to the optimizer, while data behind a `Box` is harder to reason about. The compiler cannot change a layout for you, because every function shares it [10].
7. **LAYOUT-7** **Use every byte of the cache lines you fetch.** Binary search and Eytzinger use one value per 64-byte line. An S+ tree node of `#[repr(align(64))] [u32; 16]` uses all of it [23].
8. **LAYOUT-8** **Iterate the whole dense array instead of an active-index list.** Doing constant work over every slot, with no-op neutral entries, "is much easier for a compiler to vectorize, and for a CPU Cache to prefetch" than chasing an active-index list [16].
9. **LAYOUT-9** **Group values that are always accessed together under one wrapper.** For example, use one `Arc<Mutex<(A, B)>>` rather than two separate `Arc<Mutex<_>>`s [1 §Wrapper Types].

## 6. Inlining, generics and code generation

Inlining is "the mother of all other optimizations": it gives the compiler the context it needs [8].

1. **INLINE-1** **Without `#[inline]`, non-generic functions are not inlined across crates (unless you use LTO).** Generic functions are always inlinable [8].
2. **INLINE-2** **Applications:** don't sprinkle `#[inline]`. Use LTO, and add attributes only when profiling points to a small hot function [8].
3. **INLINE-3** **Libraries:** proactively mark small, non-generic public functions `#[inline]`, especially trivial trait impls such as `Deref` and `AsRef`. Inlining is not transitive: if a public function calls a private helper, both need the attribute [8][1 §Inlining].
4. **INLINE-4** **Hot call site, cold others:** split the function into an `#[inline(always)]` body and an `#[inline(never)]` wrapper for the cold callers [1 §Inlining].
5. **INLINE-5** **Outline cold paths:**
   - Move rare code into `#[cold]` functions [1 §Inlining].
   - The pattern is "generic, inline hotpath; concrete, outline coldpath" [12].
   - Inlining a slow path can *slow the fast path*: it adds register spills and prologue/epilogue work, hoists instructions from the slow path, and can pessimize the loop [9].
6. **INLINE-6** **Always re-measure after changing inline attributes.** The effects are unpredictable: a neighbor may stop being inlined, or the code may slow down [1 §Inlining].
7. **INLINE-7** **Make hot calls statically dispatched.** Use generics (`F: Fn()`), not `fn` pointers or `dyn`, because "Function pointers and dynamic dispatch prevent inlining" [10].
8. **INLINE-8** **Contain generic bloat.** Write a thin generic shim that calls a non-generic `inner` function, as `std::fs::read` does [1 §Compile Times][8]. Measure with `cargo llvm-lines` [1 §Compile Times][12].
9. **INLINE-9** **Copy small values into locals in hot loops.** LLVM reasons much better about locals than about memory. Use `iter().copied()` for small `Copy` items [10][1 §Iterators].
10. **INLINE-10** **Make unneeded work disappear in release builds.** Use `debug_assert!` for hot checks that aren't needed for safety. Use lazy combinators (`ok_or_else`, `unwrap_or_else`, `map_or_else`) when the default is expensive [1 §Logging, §Standard Library Types]. Changing a single `ok_or` to `ok_or_else` gained up to 6% in rustc [4].

## 7. Bounds checks and loops

1. **BOUNDS-1** **Measure before you fight bounds checks.** Removing them usually gains "1% to 3%", and 15% was the most Shnatsel had ever seen. The big wins come when removal enables other optimizations, such as unrolling or vectorization [20].
2. **BOUNDS-2** **Prefer iterators in new code** (`iter`, `zip`, `chunks_exact`, `windows`). For long adapter chains, `.for_each` sometimes optimizes better than a `for` loop [20].
3. **BOUNDS-3** **Make lengths obvious to the optimizer:**
   - Loop up to `slice.len()`.
   - Re-slice to the length you need before the loop: `let b = &b[..a.len()];`
   - Index a slice rather than a `Vec`.
   - `assert!` length preconditions up front. Extra `assert!`s are free, because redundant checks get removed.

   [20][21][1 §Bounds Checks]
4. **BOUNDS-4** **Use `assert!`, not `debug_assert!`, for preconditions the optimizer should rely on.** `debug_assert!` doesn't exist in release builds, so the compiler cannot assume anything from it [20].
5. **BOUNDS-5** **Inline small helpers that index**, so the caller's length facts carry over [20].
6. **BOUNDS-6** **For untrusted hot indices, try a power-of-two table size with `i % SIZE`.** This compiles to an AND and can't go out of bounds. The trade-offs are more memory and silently wrong results instead of panics [20][21].
7. **BOUNDS-7** **Use `chunks_exact` plus `remainder()` instead of `chunks`** [1 §Iterators].
8. **BOUNDS-8** **`get_unchecked` is a last resort.** Use it only after the asm still shows `panic_bounds_check` in a hot loop, and never for constant indices into fixed-size arrays (the compiler already removes those checks) [1 §Bounds Checks][20]. High-performance search kernels do use it once proven necessary [24].
9. **BOUNDS-9** **Verify with asm:** search for `panic_bounds_check`, and remember panic paths are moved out of line [20].

## 8. SIMD and vectorization

1. **SIMD-1** **Write code that vectorizes:**
   - Process fixed-size chunks with no early exit inside a chunk.
   - Fold results with non-short-circuiting `&`/`|`.
   - Handle the tail in scalar code.

   In matklad's test, a byte loop took 650 ms, chunks with a `break` took 450 ms, and branch-free chunks took 80 ms [10].
2. **SIMD-2** **Replace early-exit scans with counting.** `data.iter().filter(|&&x| x < q).count()`-style code auto-vectorizes and was more than 2× faster than a breaking scan [23].
3. **SIMD-3** **Autovectorization is "notoriously fickle"** and can break with a compiler upgrade. On stable Rust it won't reorder float reductions [22][20]. If a kernel must stay fast, check the asm in CI or use explicit SIMD.
4. **SIMD-4** **Choosing explicit SIMD** [22]:
   - `std::simd` if nightly is acceptable.
   - `wide` if you don't need runtime dispatch.
   - `pulp` or `macerator` for multiversioning. Note `pulp` only supports native widths (NEON, AVX2, AVX-512), and only about 75% of the systems in Firefox's hardware survey have AVX2.
   - Raw `core::arch` intrinsics for C ports or specific hardware. Most are safe to call since Rust 1.87 ⏳.
   - Cache the result of `is_x86_feature_detected!`, because it "is somewhat slow".
5. **SIMD-5** **Squeeze instructions in the innermost kernel.** "Each single instruction that we remove gives a small but consistent improvement" [23]. Pre-multiply strides into byte offsets so the compiler can drop shifts and masks [23].

## 9. Memory hierarchy and latency-bound algorithms

1. **MEM-1** **Think in cache lines and memory-level parallelism, not comparison counts.** A random RAM access costs about 80 ns, but a core can have 10–12 misses in flight [23].
2. **MEM-2** **Batch independent queries** and advance them all one step at a time. This keeps many misses in flight. "batching is essentially free performance and if you can, you should always do it" [24]. Gains level off around 12–16 queries in flight [23].
3. **MEM-3** **Prefetch addresses you already know.** In Eytzinger layout, prefetch 4 levels ahead (index `16*i`). In batched tree walks, prefetch each child right after computing its index [23][24].
4. **MEM-4** **Remove unpredictable branches.** Use a fixed iteration count plus a conditional move (`select_unpredictable`, or code the compiler turns into cmov). Note that cmov removes *speculative* loads, so add explicit prefetches to make up for it [24].
5. **MEM-5** **Interleave across pipeline stages.** Overlap the CPU-bound top levels of one batch with the memory-bound bottom levels of another (29 → 24 ns) [23].
6. **MEM-6** **Use hugepages for large, randomly accessed structures.** For THP, size allocations as a multiple of 2 MB and make them at least about 32 MB [23]. jemalloc can enable THP through `MALLOC_CONF` [1 §Build Configuration].
7. **MEM-7** **Avoid integer division in hot paths.** Interpolation search lost because "integer division is just very slow" [24].
8. **MEM-8** **Check where multithreading stops scaling.** Memory-bound work saturates RAM bandwidth (6 threads: 27 → 7 ns; 8 threads: only about 4×) [23][24].
9. **MEM-9** **Use the fastest primitive that answers the question.** Vectorized substring search beats any regex engine by "at least one order of magnitude" [19]. Fast candidate detection (SIMD `memchr`) matters more than how far a Boyer-Moore search can skip [18].

## 10. Hashing and standard-library choices

1. **STD-1** **The default hasher is SipHash 1-3,** which is HashDoS-resistant and slow on short keys. When DoS isn't a concern, try `rustc-hash` (`FxHashMap`), `fnv` or `ahash`. Benchmark more than one [1 §Hashing].
   - In rustc, switching back from Fx to the default hasher regressed every benchmark, by 4–85% [5].
   - ahash was rejected there for being slightly slower and non-deterministic [5].
2. **STD-2** **Ban the type you replaced** with Clippy's `disallowed-types` so it doesn't creep back in [1 §Linting].
3. **STD-3** **Skip hashing for keys that are already random** (`nohash-hasher`). For padding-free types, consider byte-wise hashing [1 §Hashing].
4. **STD-4** **Use `vec![0; n]` for zeroed buffers.** It can use OS-zeroed pages [1 §Standard Library Types].
5. **STD-5** **Use `swap_remove` (O(1)) when order doesn't matter,** and `retain` for bulk removal [1 §Standard Library Types].
6. **STD-6** **Optimize for the common small case.** Special-casing collections of 0, 1 or 2 elements often wins. Handle the most frequent case first. Put a small cache in front of lookups with high locality [1 §General Tips]. Example: in hashbrown, a fast path for empty tables covered about a third of rustc's lookups [6].
7. **STD-7** **Measure before switching to `parking_lot`.** The std locks have improved a lot ⏳ [1 §Standard Library Types].
8. **STD-8** **Run `cargo clippy`.** Its `perf` group catches common slow patterns automatically [1 §Linting].

## 11. I/O and text processing

1. **IO-1** **Buffer file and socket I/O** with `BufReader`/`BufWriter`, then `flush()` explicitly so errors surface. Lock stdout once for repeated writes instead of calling `println!` per line [1 §I/O].
2. **IO-2** **Process bytes when you don't need UTF-8 validation.** Use `read_until` and `bstr` [1 §I/O]. Better still, compile UTF-8 handling into the automaton rather than decoding to code points [18][19].
3. **IO-3** **Don't process line by line when matches are rare.** Search large buffers, and only find line boundaries around a hit. "The overhead of each search will be your undoing" [18].
4. **IO-4** **Use cheap prefilters, then verify:**
   - Extract literals from the pattern and run the expensive engine only on candidates [18][19].
   - Pick the *rarest* byte of the needle using a byte-frequency table. Tools that scanned for the first byte were 40–50× slower on Cyrillic text [18].
   - Use Teddy (packed SIMD) for small literal sets and Aho-Corasick for tens of thousands of literals [19].
5. **IO-5** **Run the fast engine for match bounds, then the slow engine only on those bounds** (lazy DFA, then PikeVM for capture groups) [19].
6. **IO-6** **Choose mmap vs `read` by workload.** mmap was about 25% faster on one big file, but 2.5–5× slower on thousands of small files [18].
7. **IO-7** **Build lazy caches with a bounded budget and a fallback.** The lazy DFA computes only the transitions it needs, caps its memory, and gives up to a slower engine when the cache thrashes [19].
8. **IO-8** **Prefer engines with worst-case guarantees for untrusted input.** Backtracking can go exponential, and "neither type of engine has a monopoly on average case performance" [18].

## 12. Concurrency

1. **CONC-1** **Avoid sharing what you write.** Reads of a shared line are cheap. A concurrent writer made a load loop about 10× slower on older x86 [25].
2. **CONC-2** **Pad independently written atomics or locks onto separate cache lines** with `#[repr(align(64))]`, or 128 on some CPUs. False sharing took a loop from about 300 ms to "several seconds" [25]. Conversely, keep data on the same line as the atomic that guards it when they are accessed together [25].
3. **CONC-3** **Prefer native read-modify-write ops over CAS loops:**
   - `fetch_add` compiles to `lock xadd`.
   - Multi-bit `fetch_or`, `fetch_max` and similar compile to CAS loops on x86.

   [25]
4. **CONC-4** **When spinning or polling, load first and CAS only when it might succeed.** A failed CAS still takes the line exclusively [25][26].
5. **CONC-5** **Use `compare_exchange_weak` in loops** (on ARM, strong CAS adds a nested loop). Keep the instructions between load and CAS minimal [25].
6. **CONC-6** **Ordering cost is architecture-specific:**
   - On x86-64, Acquire, Release and Relaxed loads and stores compile to the same instructions. A SeqCst store becomes `xchg`, and a SeqCst fence becomes `mfence`.
   - On ARM64, Relaxed is genuinely cheaper.
   - Relaxed is "cheapest", not "free": cross-thread traffic costs regardless of ordering.
   - Test ordering-sensitive code on ARM (e.g. Apple M1). Bugs that are invisible on x86 show up there.

   [25][27]
7. **CONC-7** **Keep the uncontended lock path syscall-free.** Track waiters in the state word (0 = unlocked / 1 = locked / 2 = locked with waiters) and wake only when there are waiters. This gave 400 → 40 ms (AMD/Linux) and 1800 → 60 ms (older Intel) [26]. Wake one waiter, not all [26].
8. **CONC-8** **Spin briefly (about 100 iterations with `spin_loop()`) before parking, then benchmark.** Spinning helped on older Intel and *hurt* on newer AMD: "it depends" [26][28].
9. **CONC-9** **Use `const { … }` initializers in `thread_local!`.** The lazy form checks for initialization on every access: 487 ms vs 239 ms for C. A thread local accessed through FFI without cross-language LTO took 1198 ms [13].
10. **CONC-10** **For data parallelism, start with `rayon`,** with `crossbeam` for lower-level building blocks [1 §Parallelism].

## 13. Compile times (developer throughput)

1. **COMPILE-1** **Find the critical path with `cargo build --timings`.** Make the crate graph wide rather than a chain [1 §Compile Times][12].
2. **COMPILE-2** **Keep proc macros and serde in leaf crates.** They block pipelining, and feature unification can pull `syn` into core crates. Measure macro output with `-Zmacro-stats`; removing heavy macros cut one project's compile times by about 20% [7][12].
3. **COMPILE-3** **Reduce monomorphization.** Use non-generic `inner` functions and `&dyn Fn` for cold closures. Check with `cargo llvm-lines` [1 §Compile Times][12].
4. **COMPILE-4** **Don't sprinkle `#[inline]` everywhere.** Inline functions are compiled again in every codegen unit that uses them [8].
5. **COMPILE-5** **Have fewer test binaries.** Linking cost scales with the number of binaries [12].
6. **COMPILE-6** **In CI:**
   - Cache dependencies only.
   - Disable incremental compilation and debuginfo.
   - Split `cargo test --no-run` from running the tests.
   - Justify every entry in `Cargo.lock`.

   [12]
7. **COMPILE-7** Code size is a proxy measure. "compile time is the true measurement of interest" [7].

---

## Checklist for one optimization pass

1. Confirm it's a release build with a realistic workload. Record a baseline (instructions and wall time).
2. Profile, starting with instruction counts, then allocations, then sampling with call stacks.
3. Rank hot spots. For each one, ask: can I call it less (algorithm, caching, laziness, a special case)? Can I make it cheaper (allocation, layout, hashing, inlining, bounds checks, SIMD)?
4. Change one thing. Re-measure against the baseline on every benchmark. Explain the delta, using asm and counters if needed.
5. Keep the change only if the gain justifies its complexity and doesn't regress memory, other benchmarks or real users.
6. Lock in the win with a size assertion, an allocation test, a benchmark in CI, and a comment citing the measurement.
7. Repeat. Small wins compound.

---

## References

**Nicholas Nethercote**

1. *The Rust Performance Book*: https://nnethercote.github.io/perf-book/. Chapters are cited as §Name, e.g. §Heap Allocations → `heap-allocations.html`.
2. "How to speed up the Rust compiler one last time" (2020-09-08): https://blog.mozilla.org/nnethercote/2020/09/08/how-to-speed-up-the-rust-compiler-one-last-time/
3. "Ad Hoc Profiling" (2018-07-24): https://blog.mozilla.org/nnethercote/2018/07/24/ad-hoc-profiling/
4. "How to speed up the Rust compiler in 2018" (2018-04-30): https://blog.mozilla.org/nnethercote/2018/04/30/how-to-speed-up-the-rust-compiler-in-2018/
5. "How to speed up the Rust compiler in 2020" (2020-04-24): https://blog.mozilla.org/nnethercote/2020/04/24/how-to-speed-up-the-rust-compiler-in-2020/. Also "… some more in 2020" (weekly triage): https://blog.mozilla.org/nnethercote/2020/08/05/how-to-speed-up-the-rust-compiler-some-more-in-2020/
6. "How to speed up the Rust compiler in 2022" (2022-02-25): https://nnethercote.github.io/2022/02/25/how-to-speed-up-the-rust-compiler-in-2022.html
7. "How much code does that proc macro generate?" (2025-06-26): https://nnethercote.github.io/2025/06/26/how-much-code-does-that-proc-macro-generate.html

**Alex Kladov (matklad)**

8. "Inline In Rust" (2021-07-09): https://matklad.github.io/2021/07/09/inline-in-rust.html
9. "It's Not Always ICache" (2021-07-10): https://matklad.github.io/2021/07/10/its-not-always-icache.html
10. "Can You Trust a Compiler to Optimize Your Code?" (2023-04-09): https://matklad.github.io/2023/04/09/can-you-trust-a-compiler-to-optimize-your-code.html
11. "Hard Mode Rust" (2022-10-06): https://matklad.github.io/2022/10/06/hard-mode-rust.html
12. "Fast Rust Builds" (2021-09-04): https://matklad.github.io/2021/09/04/fast-rust-builds.html
13. "Fast Thread Locals In Rust" (2020-10-03): https://matklad.github.io/2020/10/03/fast-thread-locals-in-rust.html
14. "Fast and Simple Rust Interner" (2020-03-22): https://matklad.github.io/2020/03/22/fast-simple-rust-interner.html
15. "Newtype Index Pattern In Zig" (2025-12-23): https://matklad.github.io/2025/12/23/zig-newtype-index-pattern.html
16. "Static Allocation, Constant Work" (2026-09-02): https://matklad.github.io/2026/09/02/static-allocation-constant-work.html
17. "Do Not Optimize Away" (2025-12-09): https://matklad.github.io/2025/12/09/do-not-optimize-away.html

**Andrew Gallant (BurntSushi)**

18. "ripgrep is faster than {grep, ag, git grep, ucg, pt, sift}" (2016-09-23): https://burntsushi.net/ripgrep/
19. "Regex engine internals as a library" (2023-07-05): https://burntsushi.net/regex-internals/

**Sergey "Shnatsel" Davidoff**

20. "How to avoid bounds checks in Rust (without unsafe!)" (2023-01-17): https://shnatsel.medium.com/how-to-avoid-bounds-checks-in-rust-without-unsafe-f65e618b4c1e
21. Bounds Check Cookbook: https://github.com/Shnatsel/bounds-check-cookbook
22. "The state of SIMD in Rust in 2025" (2025-11-05): https://shnatsel.medium.com/the-state-of-simd-in-rust-in-2025-32c263e5f53d

**Ragnar Groot Koerkamp (curiouscoding.nl)**

23. "Static search trees: 40x faster than binary search" (2024-12-18): https://curiouscoding.nl/posts/static-search-tree/
24. František Kmječ and Ragnar Groot Koerkamp, "Binary search variants and the effects of batching" (2025-02-12): https://curiouscoding.nl/posts/binsearch/

**Mara Bos, *Rust Atomics and Locks* (O'Reilly, 2023)**

25. Ch. 7 "Understanding the Processor": https://marabos.nl/atomics/hardware.html
26. Ch. 9 "Building Our Own Locks": https://marabos.nl/atomics/building-locks.html
27. Ch. 3 "Memory Ordering": https://marabos.nl/atomics/memory-ordering.html
28. Ch. 4 "Building Our Own Spin Lock": https://marabos.nl/atomics/building-spinlock.html
