# Performance Engineering Rules

Language-agnostic rules for finding and fixing performance problems. Each rule cites its source. Numbers are what the authors measured on their own hardware, so treat them as orders of magnitude, not promises. Thresholds such as "above 10%" are the authors' rules of thumb.

Companion to [rust-performance-rules.md](rust-performance-rules.md), which covers Rust-specific techniques. Start here for method and measurement, then go there for Rust code patterns.

## How to use this file

- **Rule IDs are stable.** Cite a rule as `BENCH-4` or `DATA-2` in reviews, findings and commit messages. When you add a rule, append it to its section with the next number. Never renumber existing rules. Family names differ from those in the Rust file, so an ID identifies its file.
- **Families:**
  - `GEN`: general principles
  - `METHOD`: analysis methodology and estimation
  - `BENCH`: measurement and benchmarking
  - `TAIL`: latency distributions and tail latency
  - `OBS`: profiling and observability
  - `WORK`: algorithms and avoiding work
  - `API`: interface design
  - `DATA`: data layout and the memory hierarchy
  - `HEAP`: allocation and copying
  - `CPU`: pipeline, branches, vectorization and code layout
  - `PAR`: parallelism and synchronization
- **Applying a rule to code needs evidence.** `GEN`, `METHOD` and `BENCH` apply to every other rule: a finding is a candidate until a profile or benchmark shows the code matters.
- **Code audits:** `GEN`, `METHOD`, `BENCH`, `TAIL` and `OBS` describe process. The other families point to concrete code patterns.
- **Scope:** one program on one machine. The sources do not cover distributed systems; `TAIL` covers measuring a service's latency, not designing one.

## Sources

### Primary (most rules come from these)

| Source | Author | Why it matters |
|---|---|---|
| brendangregg.com methodology pages [1–10] | Brendan Gregg | Tells you where to look and in what order: the USE method, thread state analysis, off-CPU analysis, flame graphs, and a list of anti-methods. Gregg wrote *Systems Performance* and invented flame graphs. |
| *Performance Analysis and Tuning on Modern CPUs*, 2nd ed. (free) [11] and easyperf.net [12] | Denis Bakhvalov | Explains what the CPU does with your code and how to measure it: noise control, counters, top-down analysis, memory, branches, code layout, threads. |
| *Performance Hints* [13] and Fast Tips of the Week [14–21] | Jeff Dean and Sanjay Ghemawat; Abseil performance team | Code and design habits, each linked to a real change with a measured effect. The tips add measurement and estimation practice from running a large fleet. Examples are C++; the rules transfer. |

### Additional (best hits only)

| Source | Author | Focus |
|---|---|---|
| *Algorithms for Modern Hardware* [22] | Sergey Slotin | Technique, benchmark, and mechanism for branches, caches and search structures. The book is unfinished (about 75% of Part I as of March 2022), so only existing chapters are cited. All numbers come from one AMD Zen 2 laptop. |
| "Producing Wrong Data Without Doing Anything Obviously Wrong!" [23] | Mytkowicz, Diwan, Hauswirth, Sweeney | Measurement bias from memory layout. |
| "Rigorous Benchmarking in Reasonable Time" [24] | Kalibera and Jones | Where to repeat, how often, and how to report a speedup. |
| "How NOT to Measure Latency" slides and related READMEs [25–29] | Gil Tene | Coordinated omission, percentiles, and why averages mislead for latency. |

---

## 0. General principles

1. **GEN-1** **Think about performance while you write the code.** Choose the faster of two options when it costs no readability. If you neglect performance everywhere, "you will end up with a flat profile where there are no obvious hotspots because performance is lost all over the place" [13 §The importance of thinking about performance].
2. **GEN-2** **Scale the effort to where the code runs.** For test code, care about asymptotic complexity. For application code, ask whether it is setup or a hot path. For widely used library code, apply cheap local techniques by default, because "it is hard to tell how sensitive it might become" [13 §Estimation].
3. **GEN-3** **Remove work before you speed it up.** Consider the options in this order: "Don't do it / Do it, but don't do it again / Do it less / Do it later / Do it when they're not looking / Do it concurrently / Do it cheaper" [1 §Performance Mantras].
4. **GEN-4** **Fix algorithms and data structures before machine-level tuning.** "If a piece of code has a high-level performance inefficiency, you shouldn't apply machine-specific optimizations to it" [11 §8-0]. The largest wins come from lowering complexity [13 §Algorithmic improvements].
5. **GEN-5** **Predict cost from the hardware, not from operation counts.** On modern CPUs, counting operations "isn't just slightly wrong but is off by several orders of magnitude" [22 /complexity/hardware/]. Pipelining, out-of-order execution, SIMD and caches decide the running time.
6. **GEN-6** **Treat every result as guilty until you can explain it.** "Performance measurements should be considered guilty until proven innocent" [11 §2-7]. One claimed "up to 30% speedup" came from test instability and different memory modules, and fell to "within 1%" on a single machine [11 §2-7]. Scrutinize unexpectedly good results most of all [18].
7. **GEN-7** **Confirm a cause by changing only that cause.** Counters can point at an explanation; only an intervention confirms it. Change the suspected factor, re-measure, and check the effect moves as predicted [23 §7.2].
8. **GEN-8** **Keep looking after the first bottleneck.** Systems often have several problems, and "the first one you find may be a problem but not the problem" [2 §Strategy].
9. **GEN-9** **When the profile is flat, take many small wins.** "Making twenty separate 1% improvements in some subsystem is often eminently possible and collectively mean a pretty sizable improvement" [13 §What to do when profiles are flat]. This needs stable benchmarks (§2).
10. **GEN-10** **Stop when the payoff is too small.** Tune only user actions that matter to the business, and "if insufficient gain, suspend tuning until something changes" [1 §Method R]. Timebox an issue: "it would be better to try for a week and then turn their attention elsewhere" than to spend six months without success [1].
11. **GEN-11** **Test on every platform you ship to.** Tuned parameters such as block sizes depend on cache sizes, and the best setup on one machine "is not necessarily the best on another machine" [11 §8-0][23 §5].

## 1. Methodology and estimation

1. **METHOD-1** **Start with a problem statement.** Ask why you think there is a problem, whether the system ever performed well, "What has changed recently? (Software? Hardware? Load?)", and whether the problem can be stated as latency or run time. The answers often solve the issue or narrow it [1 §Problem Statement Method].
2. **METHOD-2** **Follow a named method, not the tools you happen to know.** "Analysis without a methodology can become a fishing expedition" [1]. Avoid the anti-methods [1]:
   - *Streetlight:* looking only where your familiar tools shine. You get an incomplete view and do not know it [2 §Tools Method].
   - *Random change:* changing tunables until something looks faster.
   - *Blame someone else:* redirecting the issue to another team on a guess.
   - *Traffic light:* reading a green dashboard as health.
3. **METHOD-3** **Characterize the load before you tune the system.** Ask who causes the load, why it is called, what it is, and how it changes over time. "A performance problem may simply be due to an excessive load applied", and then the fix is to change the load [1 §Workload Characterization Method][9].
4. **METHOD-4** **Check utilization, saturation and errors for every resource (USE).** Derive the resource list from the system's structure, then find a metric for each. Gregg finds it "solves about 80% of server issues with 5% of the effort" [2]. Metrics you cannot get become known unknowns [2 §In Practice].
5. **METHOD-5** **Read USE results in this order: errors, saturation, utilization.** Errors include retried and masked failures. "Any degree of saturation can be a problem." On resources that cannot be interrupted mid-operation, such as disks, queueing shows up once utilization passes about 70% [2 §Suggested Interpretations].
6. **METHOD-6** **Apply USE to software resources.** For a mutex, utilization is the time it was held and saturation is the threads queued on it. Thread pools, file descriptors and container quotas work the same way [2 §Software Resources].
7. **METHOD-7** **Break each thread's time into states and attack the largest waiting state first.** The states are executing, runnable, paging, sleeping on I/O, waiting on locks, and idle. "Tuning these latency states often provides the greatest wins, as their state time can be reduced to zero" [10].
8. **METHOD-8** **Do not read "time in component X" as X's own work.** That time includes the component's threads waiting for CPU, memory or locks held by something else: "it may be time spent in another application or tenant entirely" [10 §Where Time Is Really Spent].
9. **METHOD-9** **Split latency into synchronous parts until you find its origin.** Measure each layer as a histogram and investigate "the lowest layer that latency is introduced". Estimate the speedup of a fix before you commit to it [1 §Time Division Method, §By-Layer Method].
10. **METHOD-10** **Bisect.** Choose a test that "can exonerate many untested components (ideally, half of those remaining)" and is quick to run [1 §Process of Elimination].
11. **METHOD-11** **Estimate before you build.** Count the expensive operations in a design and "multiply each kind of expensive operation with its rough cost, and add the results together" [13 §Estimation]. Rough costs from that page:

    | Operation | Cost (ns) |
    |---|---|
    | L1 cache reference | 0.5 |
    | Branch mispredict | 5 |
    | Uncontended mutex lock/unlock | 15 |
    | Main memory reference | 50 |
    | Read 4 KB from SSD | 20,000 |
    | Datacenter round trip | 50,000 |
    | Disk seek | 5,000,000 |

    Worked example: for quicksorting a billion 4-byte integers, mispredicts (about 75 s) dominate memory transfer (about 7.5 s) [13 §Estimation].
12. **METHOD-12** **Estimate resource cost and latency separately.** Concurrency overlaps costs, so it cuts latency without cutting total work. Thirty serial disk reads take about 450 ms; spread over many disks they use the same resources in about 15 ms [13 §Estimation].
13. **METHOD-13** **Size an opportunity with a best-case bound.** Ask: "If we drove something's cost all the way to zero, would it be a worthwhile opportunity, or are there larger ones to pursue?" Add precision only if it could change the priority order [19].
14. **METHOD-14** **Compare against a "speed of light" baseline.** Benchmark a trivial stand-in that does only the unavoidable data movement. In one example `memcpy` ran at about 35 GiB/s against about 1 GiB/s for the parser, which shows the headroom [19][17].
15. **METHOD-15** **Gather data only if it could change the decision.** Ask "can the possible range of outcomes convince me to change my mind?" A second measurement from a different vantage point is worth more than more samples from the same one [20].
16. **METHOD-16** **Fix the analysis before you look at the data.** Write down the primary metric, the observation window and the bar for success first. "Choose and publish a methodology before looking at the data" [18].
17. **METHOD-17** **Start low-level CPU tuning with top-down analysis, after the high-level problems are fixed.** It sorts pipeline slots into Frontend Bound, Backend Bound, Bad Speculation and Retiring, which tells you which of §7–§9 applies. Using it "on code that has major performance flaws is not recommended because it will likely steer you in the wrong direction" [11 §6-5]. Bakhvalov's thresholds: act on Bad Speculation above 10% and Frontend Bound above 20% [11 §10-0, §11-1].
18. **METHOD-18** **With a flat profile, look up the stack.** "Take a step back and look for structural changes higher up in the call stacks instead of concentrating on micro-optimizations." Look for overly general code and replace it with a specialized version [13 §What to do when profiles are flat].

## 2. Measurement and benchmarking

### What to measure

1. **BENCH-1** **Measure useful work per resource, not proxies.** Define a productivity metric such as requests per CPU-second. Instruction counts, IPC and the share of time in one component can move the wrong way when the application gets faster. A thread spinning on a lock "is not making forward progress, despite having high IPC" [16][14].
2. **BENCH-2** **Choose a denominator that rewards real improvements.** "If a metric tells us to do the opposite of a seemingly good thing, the metric is potentially flawed." Measuring compute per byte penalizes a change that reads fewer bytes [16].
3. **BENCH-3** **Treat benchmarks as a ladder from microbenchmark to production.** Iterate at the cheap levels and confirm at the expensive ones. "Production is ultimately what matters." If a realistic test does not confirm a microbenchmark win, find out why and fix the microbenchmark: "it is likely not measuring what is intended!" [15]
4. **BENCH-4** **Know how microbenchmarks mislead.** They keep code and data cache-resident, so lookup tables and large unrolled code look better than in production: "'Faster' implementations on microbenchmarks had larger code footprints and produced worse macrobenchmark results" [15]. They also drive one component at rates real workloads never reach [8 §6].
5. **BENCH-5** **Use realistic inputs and sweep the working-set size.** A realistic input distribution stops the branch predictor from memorizing a fixed pattern. Sweep from L1-sized to several times the last-level cache. In one example a branchy parser took about 2 ns in L1 and about 8 ns at large sizes [17][15].

### Is the benchmark valid?

6. **BENCH-6** **Analyze the system while the benchmark runs, and name its limiter.** Otherwise "you benchmark A, but actually measure B, and conclude you've measured C" [7]. Check validity first and apply statistics second: "A sound statistical method can make benchmark results seem trustworthy, when in fact, they are false" [7 §Statistical Analysis].
7. **BENCH-7** **Run the benchmark checklist on every result** [8]:
   - *Why not double?* Name what stopped it being twice as fast.
   - *Was it tuned?* Configure the target as production would.
   - *Did it break limits?* Compare the implied throughput with network, bus and device limits.
   - *Did it error?* "Errors perform differently from normal operations."
   - *Does it reproduce?* Run it ten times on an idle system.
   - *Does it matter?* Check the workload is realistic.
   - *Did it even happen?* In one case a firewall blocked everything and "the reported latency was the time it took the client to time out!"
8. **BENCH-8** **Check that a microbenchmark runs the code you intend.** Keep results alive so the compiler cannot delete the work, assert correctness, and confirm with a profile that the target is the hotspot. A result of "0 nanoseconds parsing" is a bug in the benchmark [17][11 §2-6].
9. **BENCH-9** **Decide whether you are measuring throughput or latency.** Timing independent iterations measures throughput, because the CPU overlaps them. To measure latency, feed each result into the next input [17][22 /data-structures/s-tree/].
10. **BENCH-10** **Never time an instrumented build.** Instrumentation in a hot path "might easily result in a 2x slowdown of the overall benchmark" [11 §5-1].
11. **BENCH-11** **Match the timer to the event.** A system clock call costs about 500 ns and suits events longer than a microsecond. A timestamp counter read costs about 5 ns [11 §2-5].

### Noise and bias

12. **BENCH-12** **For A/B comparisons, remove nondeterminism.** Disable frequency boost and SMT, use the performance governor, pin the process, and stop competing work. On one laptop the same run took 11.99 s with turbo and 13.14 s without [11 §2-1, App. A]. Keep the production configuration when you want the effect users will see [11 §2-1].
13. **BENCH-13** **Expect bias from memory and code layout.** Changing the size of an unused environment variable changed run time "frequently by about 33% and once by almost 300%", and link order can flip the sign of a result [23 §2, §4]. Removing an unrelated function cost about 10% in one case [12], and stack alignment "has been seen to produce 20% performance swings" [15]. Warm-up runs do not remove this [11 §2-1]. The effect is smaller on large inputs [24 §8.2].
14. **BENCH-14** **To beat layout bias, vary the setup and compare distributions.** Measure both versions under many link orders and environment sizes. A bigger benchmark suite does not average the bias away [23 §7.1].
15. **BENCH-15** **Find the cause of high variance before you collect more samples.** "You should figure out what is causing performance variance and how to reduce it." Do not discard samples because they are unwanted [11 §2-4].
16. **BENCH-16** **Treat few-percent differences as A/B tests.** "When you run a program on a laptop for under a second, a ±5% fluctuation in performance is completely normal" [22 /profiling/noise/].
17. **BENCH-17** **Look at short intervals and at each CPU.** A five-minute average hid CPU bursts that hit 100% for seconds at a time [2]. A system-wide average hides one saturated core [9].

### Repetition and reporting

18. **BENCH-18** **Repeat at the highest level that varies: build, process run, or in-process iteration.** One benchmark varied 3.3% between iterations and 30.3% between process runs, so iterating within one process would have hidden most of the noise [24 §3, §7.1].
19. **BENCH-19** **Measure only after the system reaches a steady, independent state.** Find the warm-up point once per benchmark and platform by inspecting the data; automated heuristics often get it wrong. If a benchmark never settles, take the same iteration from every run [24 §6].
20. **BENCH-20** **Set repetition counts from a pilot run.** Run 20–30 repetitions at each level, see which level adds the variance, and spend the time there. Add top-level repetitions until the confidence interval is narrow enough [24 §9, §11].
21. **BENCH-21** **Compare distributions, and report a speedup as an effect size with a confidence interval.** For example: "system A is faster than system B by 5.5% ± 2.5%" at 95% confidence [24 §4, §10]. "Unless distributions have low standard deviation, do not calculate speedups" [11 §2-4].
22. **BENCH-22** **Do not mistake precision for accuracy.** Many repeated runs of a simplified load test give tight error bars around the wrong number. "For many techniques, we can only measure 1 or 2 significant digits" [21].

### Regressions

23. **BENCH-23** **Fit regression detection to the noise.** Fixed thresholds suit quiet benchmarks and pre-merge checks, but a 2% threshold missed a drift of about 15% over ten days. Change-point detection catches drift and reacts later. Keep the benchmark machine's configuration fixed, because a change invalidates the history [11 §2-3].
24. **BENCH-24** **Investigate unexpected speedups as well as slowdowns.** A sudden gain often means the code skipped work [11 §2-3].

## 3. Latency and tails

1. **TAIL-1** **Do not summarize latency with a mean and standard deviation.** Latency is multi-modal. In one data set the mean was 0.06 ms and the 99.999th percentile was 38.66 ms, about 184 standard deviations away [28 slide 38][27].
2. **TAIL-2** **Record the maximum and many high percentiles, and state requirements the same way.** "If you haven't stated percentiles and a Max, you haven't specified your requirements" [27].
3. **TAIL-3** **Never average percentiles.** "You can't average percentiles. Period" [28 slides 18–19]. Keep a histogram per interval or per thread, merge the histograms, and compute percentiles from the result [26].
4. **TAIL-4** **Measure latency from when a request should have been sent** (coordinated omission). A load generator that waits for each response stops sampling exactly when the server stalls. With a single 1.4 s stall, the corrected 99th percentile was 1.27 s against 6.04 ms uncorrected [25]. Generate load at a planned rate, or use a recorder that fills in the missed samples [26].
5. **TAIL-5** **Test the measurement tool with a stall of known length.** Pause the system for a known time and check that the reported percentiles match. "Don't waste time analyzing until you establish sanity" [27][28 slides 42–44].
6. **TAIL-6** **Pick the percentile to watch from the fan-out.** If a user action makes N requests, the chance it sees at least one response beyond percentile p is 1 − p^N. With 69 requests, half of page loads see the 99th percentile. The formula assumes slow responses are not correlated in time [29][28 slides 27–28].
7. **TAIL-7** **Report throughput only with the latency behind it.** "Measuring throughput without latency behavior is [usually] meaningless." Compare systems at fixed load below saturation, where the latency target still holds [27][28].
8. **TAIL-8** **Sampling profilers average away rare stalls; trace them instead** [11 §5-5, §5-2]. See `OBS-10`.
9. **TAIL-9** **Pre-fault and lock memory before a latency-critical path.** A first touch of new memory takes a page fault that costs "just under a microsecond up to several microseconds" [11 §12-4].
10. **TAIL-10** **Keep address-space changes off the critical path in threaded programs.** Unmapping memory or changing protections interrupts every core that runs the process, and the cost grows with thread count [11 §12-4].

## 4. Profiling and observability

### Time on and off the CPU

1. **OBS-1** **Account for blocked time.** CPU profilers sample only running threads. In one example a command took 50.8 s of wall time and 12.6 s of CPU time: "We are missing 38.2 seconds!" Profile off-CPU time with stack traces to explain the gap [3]. Lock contention "can often artificially lower CPU usage" [13 §Profiling tools and tips].
2. **OBS-2** **Count blocking only on the request path.** Idle workers waiting for work dominate a raw off-CPU profile. Filter to request context before you rank stacks [3 §Request-Synchronous Context].
3. **OBS-3** **Find the waker.** A blocked stack shows where a thread waited. The reason is often in the thread that woke it [3 §Wakeups].
4. **OBS-4** **Separate scheduler delay from real blocking.** Off-CPU time includes waiting for a CPU after wakeup. Stacks with no reason to block are often involuntary context switches on saturated CPUs [3 §Caveats].
5. **OBS-5** **Do not read high CPU utilization as productive work.** A busy CPU may be stalled on memory or spinning on a lock [11 §4-2]. IPC gives a first hint: memory-bound code usually runs at 0–1 and compute-bound code at 4–6. Compare IPC only at equal clock frequency [11 §4-3].

### Reading profiles

6. **OBS-6** **Make stack walking work before you trust a profile.** Without frame pointers or symbols, partial stacks land in the wrong place and still look plausible. Frame pointers usually cost under 1% and have exposed wins "ranging from 5% to 500%" [6]. Always collect call stacks: a flat list does not show which caller makes a shared function hot [11 §5-5].
7. **OBS-7** **Read a flame graph as a population, not a timeline.** Width is how often a frame appeared in samples. A wide frame may be slow per call or just called often; sampling does not record call counts [4 §Description].
8. **OBS-8** **Look at the whole profile.** In one case the top stacks of a text report covered under 3% of samples, and the flame graph showed where the time really went [4]. Aim to understand everything above 1% [1 §CPU Profile Method].
9. **OBS-9** **Diagnose a regression with a before/after profile diff.** Normalize the sample counts first, or a change in load colors everything. View the diff in both directions so that code paths which vanished still show [5].
10. **OBS-10** **Sample to find hotspots; trace to find rare events.** Sampling is cheap but skips short stalls. Tracing records every event, and its cost scales with the event rate [11 §5-5, §5-2].
11. **OBS-11** **Sample at off-beat rates such as 99 Hz,** so samples do not line up with periodic activity [4].

### Counters and overhead

12. **OBS-12** **Turn raw counts into rates before you call something a problem.** A billion cache misses is half of two billion loads, or one in a thousand of a trillion [11 §4-9].
13. **OBS-13** **Treat multiplexed counter values as estimates.** When you request more events than the CPU has counters, the tool time-slices and scales them, which is only reliable for steady workloads [11 §5-3].
14. **OBS-14** **Use precise sampling to blame one instruction.** Ordinary samples land some distance past the culprit, and "this skid can be hundreds of processor instructions" [11 §6-7].
15. **OBS-15** **Measure the cost of the tool.** Tracing context switches cost 6–13% in one test even when summarized in the kernel. Start with a trace of a tenth of a second [3 §Overhead]. Keep production profiling below about 1% by sampling fewer machines, less often [11 §2-2].
16. **OBS-16** **Know your profiler's blind spots.** A sampling profiler systematically omits some events, such as empty tables or long-lived objects [20].
17. **OBS-17** **Weigh statistics and logging on hot paths.** Each counter has a running cost; sampling stats 1 in 32 instead of 1 in 10 took one packet path from 224 ns to 85 ns [13 §Reduce stats collection costs]. A disabled log statement still costs a load and a compare, and hoisting the enabled check out of a loop gave 8–10% [13 §Avoid logging on hot code paths].

## 5. Algorithms and avoiding work

1. **WORK-1** **Look for asymptotic improvements first.** "The most critical opportunities for performance improvements come from algorithmic improvements, e.g., turning an O(N²) algorithm to O(N lg(N)) or O(N)". Check that hash functions spread keys, or hash lookups become O(N) [13 §Algorithmic improvements].
2. **WORK-2** **Add a short fast path for the common case.** Keep the inlined fast path minimal and move the rest out of line. A smaller fast path also cuts instruction-cache pressure [13 §Fast paths for common cases].
3. **WORK-3** **Compute once.** Precompute expensive properties as flags or tables, validate input once at the module boundary, and move invariant work out of loops [13 §Precompute expensive information once, §Move expensive computations outside loops].
4. **WORK-4** **Defer work until it is needed, and order work so later steps can be skipped.** Deferring one call until needed "reduces 43 seconds of CPU time to 2 seconds". Changing a search order gave a 19% throughput gain [13 §Defer expensive computation].
5. **WORK-5** **Specialize hot call sites.** A hot caller often needs a fraction of a general library. Custom printing code was "4x as fast as sprintf" [13 §Specialize code]. Cache repeated results under a cheap fingerprint of the input [13 §Use caching to avoid repeated work].
6. **WORK-6** **Use simpler structures at small sizes.** On a small array, "a linear scan is usually faster even though it has worse algorithmic complexity", because binary search mispredicts [11 §8-0]. For small dense key ranges, use an array instead of a map and a bit vector instead of a set [13 §Arrays instead of maps, §Bit vectors instead of sets].
7. **WORK-7** **Process several items per operation.** Compare many bytes with one SIMD instruction, or decode integers in groups. One grouped format decoded four integers in about a third of the time [13 §Bulk operations].
8. **WORK-8** **Lay out static search data for the cache.** A branchless binary search is 2.5–3× faster on small arrays. Storing the array in breadth-first (Eytzinger) order with prefetching is about 2× faster than the standard routine on large arrays [22 /data-structures/binary-search/]. A B-tree layout with one cache line per node, searched with SIMD, is up to 15× faster in throughput [22 /data-structures/s-tree/].

## 6. Interface design

1. **API-1** **Keep optimizations behind narrow interfaces, and do not over-promise.** Organize code so data structures can change "without affecting public interfaces". Every guarantee costs users who do not need it; pointer-stable containers allocate more because of that promise [13 §API considerations].
2. **API-2** **Offer bulk operations.** They amortize locks and boundary crossings and allow better algorithms. Building a heap in bulk takes O(N) against O(N lg N) one element at a time [13 §Bulk APIs].
3. **API-3** **Take non-owning views as parameters.** Slices and string views "reduce copying, and allow callers to pick their own container types" [13 §View types].
4. **API-4** **Let callers pass scratch space or values they already have,** such as a buffer or the current time, so the callee does not allocate or recompute [13 §Pre-allocated/pre-computed arguments].
5. **API-5** **Make general-purpose types safe for external synchronization, not internally locked.** "This way callers who do not need thread-safety don't pay for it." Put the lock inside only when nearly every use needs one [13 §Thread-compatible vs. Thread-safe types].
6. **API-6** **Do not use a wire format as an in-memory data structure.** Summing 1000 points was 20× faster with plain structs than with protobuf messages, and in-memory messages are often 5× the wire size [13 §Protocol Buffer advice].
7. **API-7** **Keep rich error types off hot routines that rarely fail.** They cost something on success too. Removing one from a hot path "eliminated a 14% CPU regression" [13 §C++-Specific advice]. The example is C++.

## 7. Data layout and the memory hierarchy

### Layout

1. **DATA-1** **Count cache lines touched, not memory accesses.** Memory moves in whole lines. A loop that read every 16th integer of a large array ran no faster than one that read them all [22 /cpu-cache/cache-lines/]. Compact representations win by "touching fewer cache lines" [13 §Compact data structures].
2. **DATA-2** **Remove padding and oversized fields.** Order fields by alignment and use the smallest types that fit. One change to 32-bit sizes "saves ~8TiB of memory in Spanner" [13 §Memory layout][11 §8-2].
3. **DATA-3** **Group fields by how they are used.** Put fields that are read together next to each other, and move cold fields behind a pointer or into a separate array. Keep hot read-only fields away from hot mutable fields, so writes do not evict them [13 §Memory layout][11 §8-2].
4. **DATA-4** **Choose array-of-structures or structure-of-arrays by what the hot loop touches.** If it reads a few fields across many objects, split the fields into arrays, which also enables vectorization. If it uses every field of one object, keep them together, so one miss brings in the whole record [11 §8-0][22 /cpu-cache/aos-soa/].
5. **DATA-5** **Use indices instead of pointers.** A 32-bit index into an array halves the reference and keeps the elements contiguous [13 §Indices instead of pointers].
6. **DATA-6** **Prefer flat containers to node-per-element containers.** "By default, stay away from data structures that rely on pointers, e.g. linked lists or trees" [11 §8-2]. Replacing a tree set with a vector-backed heap took an operation from 771 ns to 281 ns [13 §Batched storage].

### Access patterns

7. **DATA-7** **Access memory sequentially, in layout order.** This uses whole cache lines and lets the hardware prefetcher run ahead. Interchange loops to match the array's layout [11 §8-2, §9-3].
8. **DATA-8** **Avoid chains of dependent loads.** Chasing pointers through a random permutation is slower than a linear scan "by multiple orders of magnitude" [22 /cpu-cache/latency/]. When random access is unavoidable, run several independent lookups at once so their misses overlap; the hardware sustains a dozen or more [22 /cpu-cache/mlp/].
9. **DATA-9** **Block loops so the working set fits in cache.** Blocking keeps data in cache until it is reused [11 §9-3]. A blocked, vectorized matrix multiply ran 50× faster than the naive loop [22 /algorithms/matmul/].
10. **DATA-10** **Avoid power-of-two strides and dimensions.** They map hot data into a few cache sets. Stride 257 ran 10× faster than stride 256 [22 /cpu-cache/associativity/]. Pad the dimension or block the loop [11 §12-2].
11. **DATA-11** **Prefetch in software only when the address is known early and the hardware cannot guess it.** Insert the prefetch well ahead of the use, then confirm that cache misses fell [11 §8-6]. "You actually fail more often than not" with software prefetching [22 /cpu-cache/prefetching/].

### Memory system limits

12. **DATA-12** **Use huge pages for random access over a large footprint.** Gains reach 30% under heavy TLB pressure, though half of one benchmark suite gained under 1%. Transparent huge pages are easier but add allocation latency [11 §8-5][22 /cpu-cache/paging/].
13. **DATA-13** **If memory bandwidth is the limit, move fewer bytes.** Compute tuning and extra threads stop helping; one workload saturated the bus with 3 threads. Compress or quantize the data, which cuts traffic "by 2x or 4x" [11 §8-4, §13-3].
14. **DATA-14** **Align vector data so accesses do not straddle cache lines.** A split access reads two lines. Aligning each matrix row changed performance by up to 30% [11 §12-2].
15. **DATA-15** **Use streaming stores for large write-only output.** An ordinary store to uncached memory reads the line first, which doubles bus traffic. Do not use them for data you will read again soon [22 /cpu-cache/bandwidth/].

## 8. Allocation and copying

1. **HEAP-1** **Reduce allocations, guided by an allocation profile.** Each allocation costs allocator time, and "tends to be on a new cache line", which spreads data out. One change raised throughput 21% [13 §Avoid unnecessary allocations].
2. **HEAP-2** **Pre-size containers when you know the size.** Do not reserve one element at a time, which "may lead to quadratic behavior", and do not over-reserve: preallocating 10 nodes instead of 200 cut a web server's CPU use by 7.5% [13 §Resize or reserve containers, §Defer expensive computation].
3. **HEAP-3** **Use inline storage for collections that are usually small,** so the common case allocates nothing. Avoid it when elements are large [13 §Inlined storage].
4. **HEAP-4** **Use arenas for objects that live and die together.** They cut allocation cost and pack related objects together [13 §Arenas]. Arenas in major frameworks gave "15-30% more work per CPU", far more than the destructor cost they removed [14]. Per-thread arenas avoid allocator lock contention [11 §8-3]. Do not put short-lived objects in a long-lived arena [13 §Arenas].
5. **HEAP-5** **Avoid copies.** Move instead of copying, store references into source data, and sort indices instead of large objects. Removing one copy sped up a 400 KB transfer by 10–15% [13 §Avoid copying when possible].
6. **HEAP-6** **Reuse temporaries across loop iterations.** Hoist the buffer out of the loop and clear it each time. Rebuild it now and then, because it keeps its largest-ever capacity [13 §Reuse temporary objects].

## 9. CPU: pipeline, branches, vectorization, code layout

### Dependencies and vectorization

1. **CPU-1** **Break the critical dependency chain.** A loop-carried chain runs at the instruction's latency, not its throughput. Split it into several independent accumulators and merge at the end. Splitting one recurrence in two took time per iteration from 19 ms to 10 ms [11 §9-1][22 /pipelining/throughput/].
2. **CPU-2** **Interleave long independent chains by hand.** The out-of-order window cannot reach a second chain thousands of instructions later, and the compiler will not interleave them [11 §9-1].
3. **CPU-3** **Break dependencies that pass through memory.** Repeated read-modify-write of one location, as in a histogram of similar values, serializes the loop. Alternating between partial histograms gave 10–50% [11 §12-2].
4. **CPU-4** **Check that hot loops are vectorized and that the vector path runs.** Read the compiler's report or the assembly. Common blockers are possible aliasing, floating-point reassociation, and low trip counts. Vectorization "usually yields a 5-10x speedup" [11 §9-4][22 /simd/auto-vectorization/].
5. **CPU-5** **Leave unrolling and inlining to the compiler unless a profile says otherwise.** "Always measure the performance of the changed code before forcing a compiler to inline a function" [11 §9-2, §9-3]. Hand-written low-level rewrites should follow a profile, "since compilers will often get things right on their own" [13 §Make the compiler's job easier].

### Branches

6. **CPU-6** **Replace only branches that mispredict.** A mispredict costs 10–25 cycles [11 §4-8]. A conditional select avoids it but computes both sides, so it pays "only if the branch is hard to predict" [11 §10-3]. In one test the branch won once it was predictable more than about 75% of the time [22 /pipelining/branchless/].
7. **CPU-7** **Execute fewer branches.** Replace multi-way data-dependent branches with a table lookup or arithmetic. Test many elements at once and branch once per chunk: 16 characters per test gave "5--6 times fewer branch instructions and more than 4x better performance" [11 §10-1, §10-4].
8. **CPU-8** **Replace division by a repeated runtime divisor with multiply and shift.** Division takes 10–20 cycles. Compilers already do this for constants, so keep constant divisors visible to them [22 /arithmetic/division/].

### Code layout

9. **CPU-9** **Make the hot path fall through.** Mark rare paths unlikely, move large cold blocks into separate functions, and place hot functions together [11 §11-3, §11-5, §11-6].
10. **CPU-10** **Use profile-guided optimization for front-end-bound code.** It gives up to 30% on workloads with severe front-end stalls, and post-link optimizers often add 5–10%. Train only on representative workloads [11 §11-7].
11. **CPU-11** **Treat code size as a cost, and measure hot code, not binary size.** Large code means "more icache pressure". Move error formatting out of line and collapse redundant generic instantiations [13 §Code size considerations]. "It's the amount of hot code that matters" [11 §11-9]. Mapping large hot code onto huge pages can halve instruction-TLB misses [11 §11-8].
12. **CPU-12** **Flush subnormal floats to zero when precision allows.** Arithmetic on subnormal values "can run 10 times slower or more", and the cost does not show as a stall [11 §12-2].

## 10. Parallelism and synchronization

1. **PAR-1** **Speed up the critical path.** Improving a thread that is not on it does not reduce latency. A hotspot profile does not show which code that is; a causal profiler estimates it [11 §13-2, §13-7].
2. **PAR-2** **Parallelize in batches, and check for spare capacity.** Batch items "to avoid paying the cost of running something in parallel per item". If CPUs or memory bandwidth are already saturated, parallelism "may not help, or may even hurt" [13 §Exploit parallelism].
3. **PAR-3** **Run tiny work items inline.** Below a size threshold, handing work to another thread costs more than the work [13 §Reduce frequency of context switches].
4. **PAR-4** **Keep critical sections short.** Do no I/O or remote calls under a lock, watch for expensive destructors, and touch few cache lines [13 §Keep critical sections short].
5. **PAR-5** **Take a lock once per batch, not once per element,** unless that raises contention [13 §Amortize lock acquisition].
6. **PAR-6** **Shard contended structures.** Sharding a cache 16 ways roughly doubled throughput under load. Pick shard bits that the inner hash table does not reuse [13 §Reduce contention by sharding].
7. **PAR-7** **Do not let threads write the same cache line.** An atomic counter written by many threads "effectively serializes accesses"; accumulate per thread and merge. Pad separate per-thread data onto separate lines, and do not hard-code the line size [11 §13-6]. Padding grows objects, so confirm the gain [13 §Reduce false sharing].
8. **PAR-8** **When code does not scale, check frequency and shared resources first.** More active cores run at a lower clock, and memory bandwidth and the last-level cache are shared. With frequency boost off, one program's 16-thread scaling went from 38% to 69% [11 §13-3].
9. **PAR-9** **Split work dynamically and do not oversubscribe.** On uneven cores, pinned threads with static partitions leave a long tail on the slow cores. High time spent preempted signals too many threads [11 §13-4, §13-1].

---

## Checklist for one investigation

1. State the problem as latency or run time, and ask what changed (`METHOD-1`). Estimate the best-case gain before starting (`METHOD-13`).
2. Check every resource for errors, saturation and utilization (`METHOD-4`). Break thread time into states (`METHOD-7`).
3. Profile both on-CPU and off-CPU time with working stacks (`OBS-1`, `OBS-6`). Explain everything above 1% (`OBS-8`).
4. Build a benchmark you have validated while it runs (`BENCH-6`, `BENCH-7`), on a quiet machine (`BENCH-12`).
5. For each hot spot, ask in order: can the work be removed, cached, reduced or deferred (`GEN-3`, §5)? Is the data laid out for the cache (§7)? Only then tune the CPU path (§9).
6. Change one thing. Compare distributions against the baseline and report an interval (`BENCH-21`). Explain the result (`GEN-6`, `GEN-7`).
7. Confirm at a more realistic level (`BENCH-3`). For services, check the tail, not the mean (§3).
8. Guard the win with a regression check (`BENCH-23`). Repeat, or stop when the payoff is too small (`GEN-10`).

---

## References

**Brendan Gregg**

1. "Performance Analysis Methodology" (updated 2025-01-23): https://www.brendangregg.com/methodology.html. Sections are cited by name.
2. "The USE Method" (updated 2017-08-24): https://www.brendangregg.com/usemethod.html
3. "Off-CPU Analysis" (updated 2017-12-27): https://www.brendangregg.com/offcpuanalysis.html
4. "CPU Flame Graphs" (updated 2021-08-30): https://www.brendangregg.com/FlameGraphs/cpuflamegraphs.html
5. "Differential Flame Graphs" (2014-11-09): https://www.brendangregg.com/blog/2014-11-09/differential-flame-graphs.html
6. "The Return of the Frame Pointers" (2024-03-17): https://www.brendangregg.com/blog/2024-03-17/the-return-of-the-frame-pointers.html
7. "Active Benchmarking" (updated 2014-04-20): https://www.brendangregg.com/activebenchmarking.html
8. "Evaluating the Evaluation: A Benchmarking Checklist" (2018-06-30): https://www.brendangregg.com/blog/2018-06-30/benchmarking-checklist.html
9. "Linux Performance Analysis in 60,000 Milliseconds" (2015-11-30): https://www.brendangregg.com/Articles/Netflix_Linux_Perf_Analysis_60s.pdf
10. "The TSA Method" (updated 2014-02-02): https://www.brendangregg.com/tsamethod.html

**Denis Bakhvalov**

11. *Performance Analysis and Tuning on Modern CPUs*, 2nd ed. (2024), source at https://github.com/dendibakh/perf-book. Cited as §N-M, the file whose name starts with `N-M` under https://github.com/dendibakh/perf-book/tree/main/chapters, e.g. §8-2 → `8-Optimizing-Memory-Accesses/8-2 Cache-Friendly Data Structures.md`. App. A is `18-Appendix/Appendix-A.md`.
12. "Code alignment issues" (2018-01-18): https://easyperf.net/blog/2018/01/18/Code_alignment_issues

**Jeff Dean, Sanjay Ghemawat and the Abseil performance team**

13. Jeff Dean and Sanjay Ghemawat, "Performance Hints" (2023-07-27, updated 2025-12-16): https://abseil.io/fast/hints.html. Sections are cited by heading.
14. Fast TotW #7, "Optimizing for application productivity" (2019-06-06): https://abseil.io/fast/7
15. Fast TotW #39, "Beware microbenchmarks bearing gifts" (2021-01-22): https://abseil.io/fast/39
16. Fast TotW #70, "Defining and measuring optimization success" (2023-06-26): https://abseil.io/fast/70
17. Fast TotW #75, "How to microbenchmark" (2023-09-29): https://abseil.io/fast/75
18. Fast TotW #88, "Measurement methodology: Avoid the jelly beans trap" (2024-11-07): https://abseil.io/fast/88
19. Fast TotW #90, "How to estimate" (2025-02-06): https://abseil.io/fast/90
20. Fast TotW #94, "Decision making in a data-imperfect world" (2025-06-26): https://abseil.io/fast/94
21. Fast TotW #98, "Measurement has an ROI" (2025-08-23): https://abseil.io/fast/98

**Sergey Slotin**

22. *Algorithms for Modern Hardware*: https://en.algorithmica.org/hpc/. Cited by path, e.g. /cpu-cache/cache-lines/ → https://en.algorithmica.org/hpc/cpu-cache/cache-lines/.

**Measurement validity**

23. Todd Mytkowicz, Amer Diwan, Matthias Hauswirth and Peter F. Sweeney, "Producing Wrong Data Without Doing Anything Obviously Wrong!" (ASPLOS 2009): https://doi.org/10.1145/1508244.1508275. Authors' page: https://sape.inf.usi.ch/publications/asplos09
24. Tomas Kalibera and Richard Jones, "Rigorous Benchmarking in Reasonable Time" (ISMM 2013): https://doi.org/10.1145/2464157.2464160. Author's copy: https://kar.kent.ac.uk/33611/

**Gil Tene**

25. wrk2 README, "A note about wrk2's latency measurement technique": https://github.com/giltene/wrk2
26. HdrHistogram README: https://github.com/HdrHistogram/HdrHistogram
27. "How Not to Measure Latency" slides (QCon SF 2012): https://qconsf.com/sf2018/sf2012/dl/qcon-sanfran-2012/slides/GilTene_HowNotToMeasureLatency.pdf
28. "How NOT to Measure Latency" slides (QCon SF 2015): https://www.slideshare.net/slideshow/how-not-to-measure-latency-60111840/60111840. Talk video: https://www.infoq.com/presentations/latency-response-time/
29. "#LatencyTipOfTheDay: MOST page loads will experience the 99%'lie server response" (2014-06-28): https://latencytipoftheday.blogspot.com/2014/06/latencytipoftheday-most-page-loads.html
