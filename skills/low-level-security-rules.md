# Low-Level Security Rules

Rules for memory safety and other low-level security in systems code. Each rule cites its source. Statistics are dated and come from the authors' own products, so treat them as evidence of direction, not as constants. Compiler flags and version numbers change; check them against your toolchain.

This file covers one process and its trust boundaries with the kernel, other processes, and foreign code. Protocol design, authentication, web security and network-service hardening belong in a separate file.

## How to use this file

- **Rule IDs are stable.** Cite a rule as `INT-1` or `FFI-3` in reviews, findings and commit messages. When you add a rule, append it to its section with the next number. Never renumber existing rules. Family names differ from those in [performance-rules.md](performance-rules.md) and [rust-performance-rules.md](rust-performance-rules.md), so an ID identifies its file.
- **Families:**
  - `THREAT`: threat model and principles
  - `ARCH`: architecture, privilege and trust boundaries
  - `LANG`: language choice and safe-coding strategy
  - `SPATIAL`: bounds and buffer overflows
  - `TEMPORAL`: lifetimes, use-after-free and ownership
  - `INT`: integer overflow, conversions and sizes
  - `INIT`: uninitialized memory and information leaks
  - `TYPE`: type confusion, casts and layout
  - `UB`: undefined behavior and compiler assumptions
  - `RACE`: data races and check-then-use races
  - `UNSAFE`: Rust `unsafe` and other unsafe subsets
  - `FFI`: foreign function interfaces
  - `HARDEN`: compiler flags and runtime mitigations
  - `SECRET`: secret handling, constant time and randomness
  - `VERIFY`: fuzzing, sanitizers, review and patching
- **Language scope.** A rule applies to any language unless it starts with a tag: *(C/C++)*, *(C++)*, *(Rust)* or *(GCC/Clang)*. Many C rules also apply to Rust `unsafe` code and to FFI; the rule says so where the source does.
- **Order of defense.** Prevent the bug (`LANG`, `SPATIAL` through `FFI`), then contain it (`ARCH`), then make it hard to exploit (`HARDEN`), then find what is left (`VERIFY`). Later layers do not replace earlier ones (`THREAT-12`).

## Sources

### Primary

| Source | Author | Why it matters |
|---|---|---|
| "SoK: Eternal War in Memory" (IEEE S&P 2013) [1] | Szekeres, Payer, Wei, Song | The model: how a memory error becomes an exploit, and which defense stops which step. Its deployment facts are from 2013; the model has not dated. |
| SEI CERT C and C++ Coding Standards [2, 3] | CMU Software Engineering Institute | Code-level rules with stable IDs and a risk rating each. Rules are cited by CERT ID. |
| Chromium security docs and Google memory-safety reports [4–15] | Chrome Security, Android Security and Google Security Engineering | Design rules (the Rule of 2, IPC validation) and fleet data on which bugs occur and what reduces them. |
| Compiler Options Hardening Guide for C and C++ [16] and Linux Kernel Self-Protection [17] | OpenSSF; Linux kernel developers | Which mitigations to enable, what each stops, and what each costs. |
| *The Rustonomicon* [18] and ANSSI Secure Rust Guidelines [19] | Rust project; French national cybersecurity agency | Soundness rules for `unsafe` and FFI. ANSSI rules are cited by their ID. |

### Additional (best hits only)

| Source | Author | Focus |
|---|---|---|
| 0-day root cause analyses and yearly reviews [20–25] | Google Project Zero and Threat Analysis Group | How real bugs were exploited, and why patches failed. Cases are cited by CVE. |
| Cryptocoding [26] and BearSSL constant-time notes [27, 28] | Jean-Philippe Aumasson; Thomas Pornin | Handling secrets: constant time, wiping memory, randomness. |
| Testing Handbook [29] | Trail of Bits | Fuzzing and sanitizer practice. |

---

## 0. Threat model and principles

1. **THREAT-1** **Assume every developer makes mistakes that become vulnerabilities.** "Our threat model is that all software developers make mistakes, and sometimes those mistakes lead to vulnerabilities" [16 §Background]. Design so that a mistake is prevented, contained, or caught.
2. **THREAT-2** **Expect memory-safety bugs to dominate severe vulnerabilities in C and C++.** "Around 70% of our high severity security bugs are memory unsafety problems (that is, mistakes with C/C++ pointers). Half of those are use-after-free bugs" [5]. Of 58 in-the-wild 0-days in 2021, "39, or 67% were memory corruption vulnerabilities" [22].
3. **THREAT-3** **One memory error grows into arbitrary read and write.** An exploit makes a pointer invalid, out of bounds or dangling, and then uses it. "With one memory error, more and more memory errors can be raised by corrupting other pointers" [1 §II-A]. Do not rate a bug as "only" a small write.
4. **THREAT-4** **Defend reads as well as writes.** A value loaded through an attacker-controlled pointer is attacker-controlled: an unchecked jump-table index hijacks control flow without any write. Reads also leak the secrets that other defenses rely on [1 §II-A, §VII-A].
5. **THREAT-5** **Protect data, not only control flow.** An attacker can win by overwriting a flag, a user identity or a key. "The target of the corruption can be any security critical data in memory, e.g., configuration data, the representation of the user identity, or keys" [1 §II-D]. Control-flow integrity does nothing against this.
6. **THREAT-6** **Treat every information leak as a mitigation bypass.** Canaries and address randomization work only while their secret stays secret, and those secrets "can not only be guessed, but also leaked" [1 §IV-A]. Use separate, high-entropy secrets, such as a different canary per stack [17 §Probabilistic defenses].
7. **THREAT-7** **Design so that one bug is not enough.** Real exploits are chains: an information leak, then code execution, then a sandbox or kernel escape. One iOS leak "was used after the Safari RCE (CVE-2020-27930) and before the kernel privilege escalation (CVE-2020-27932)" [20 CVE-2020-27950]. Each added boundary costs the attacker another bug [25].
8. **THREAT-8** **Assume the less-privileged side is fully compromised.** Design a privileged component as if the attacker "has arbitrary read and write access" to it [17], and treat data from a less trusted process "as if it were generated by a malicious adversary" [9 §Do not trust less privileged processes].
9. **THREAT-9** **Treat any input with a non-trivial grammar as hostile, and the parsed values too.** "It is very rare to find a grammar trivial enough that we can trust ourselves to parse it successfully or fail safely." After safe parsing, the value is still untrusted: a path can still contain `../` [4]. The more a parser branches on input bytes, the more control the attacker has [4 §Processing, Parsing, And Deserializing].
10. **THREAT-10** **Trust a source only on cryptographic proof.** A trustworthy source is one you "can cryptographically prove" comes from an entity you trust. A common pattern delivers a hash over a trusted channel and the content over an untrusted one [4 §Verifying The Trustworthiness Of A Source].
11. **THREAT-11** **Remove bug classes, not single bugs.** Attackers reuse known patterns. After Chrome deployed a use-after-free mitigation, "in 2023 there were no use-after-free vulnerabilities exploited in Chrome for the first time since we began seeing Chrome zero days in-the-wild" [25].
12. **THREAT-12** **Mitigations raise cost; they do not fix the bug.** A useful mitigation makes attackers "chain additional vulnerabilities, or invent a novel bypass technique" [7 §Exploit Mitigations]. "Compiler options hardening is not a silver bullet" [16].
13. **THREAT-13** **A defense ships only if it is cheap and never wrong.** Techniques with overhead "larger than roughly 10% do not tend to gain wide adoption", and "causing faults in normal operation is unacceptable in production environments" [1 §IV]. Prefer defenses that are on by default and need no opt-in [17].
14. **THREAT-14** *(Rust)* **Safe does not mean correct.** Safe Rust still allows deadlocks, race conditions, memory leaks and integer overflow [18 what-unsafe-does][19 guarantees]. Keep resource exhaustion and logic races in the threat model.

## 1. Architecture, privilege and trust boundaries

### Where untrusted input is handled

1. **ARCH-1** **The Rule of 2: never combine untrusted input, an unsafe language, and high privilege.** Remove one of the three: use a safe language, sandbox the code, or prove the source trustworthy. Chrome "will generally not approve landing a CL or new feature that involves all 3" [4].
2. **ARCH-2** **Parse untrusted data in a low-privilege process, and validate the result again in the privileged one.** "Only the browser can trust itself to validate and act on the meaning of an object" [4 §Privilege Reduction].
3. **ARCH-3** **Normalize complex formats into a trivial one before they cross into higher privilege.** Decode an image in the sandbox and pass raw pixels and dimensions. Then a compromised sandbox can only feed "a simple, plausibly-safe parser" [4 §Normalization].
4. **ARCH-4** **Keep parsers that run without user interaction out of the kernel.** A video-parameter overflow became remotely reachable when a kernel driver was used for "thumbnailing of incoming images in iMessage". The suggested fix was "removing the H.264 parameter parsing code from the kernel and running it in a lower-privileged context" [20 CVE-2022-22675].
5. **ARCH-5** **Reduce the code an attacker can reach.** "The most fundamental defense against security exploits is to reduce the areas of the kernel that can be used to redirect execution" [17 §Attack Surface Reduction]. Filter entry points, and never let an unprivileged user load new code [17]. Keep the most privileged process small: "it has all the secrets" [14]. Do not add ad hoc message channels into it; each one "presents a risk of a sandbox escape" [15].
6. **ARCH-6** **Know the limits of sandboxing.** "The process is the smallest unit of isolation, but processes are not cheap" [5]. Reusing a sandbox across requests weakens it [7]. Fix bugs at the source where you can.

### Messages across a privilege boundary

7. **ARCH-7** **Validate everything a less-privileged peer sends.** "Message handlers cannot assume that offsets are valid, calculations won't overflow" [9]. Never dereference a pointer from a message. One fix that "simply changed the raw pointers to offsets" was bypassed; the complete fix confined every copy to the message buffer [20 CVE-2020-0986].
8. **ARCH-8** **Derive privilege-related facts on the privileged side.** The broker should already know the caller's identity and rights. "A method that requires passing an origin from the renderer to the browser process has a conceptual error, and quite possibly, a vulnerability" [9].
9. **ARCH-9** **Define messages so that every representable value is valid.** Use structured types and tagged unions, and "avoid parallel arrays of data that require the receiver to validate that the arrays have matching lengths" [9]. Generate both directions of a serializer from one schema: with hand-written pairs, "if there is a mismatch between these, that's usually a security bug" [20 CVE-2023-20963].
10. **ARCH-10** **Reject bad input by terminating the sender, not by asserting in the receiver.** "A compromised sender can trigger a `CHECK()` to crash the receiving process" [9 §ReportBadMessage vs CHECK].
11. **ARCH-11** **Never execute or implicitly read less-privileged memory from a privileged context.** "The kernel must never execute userspace memory. The kernel must also never access userspace memory without explicit expectation to do so" [17 §Segregation of kernel memory from userspace memory].

### Process and dependency hygiene

12. **ARCH-12** **Do not run commands through a shell.** Pass an argument vector to an `exec` function, which "does not use a full shell interpreter, so it is not vulnerable to command-injection attacks" [2 ENV33-C].
13. **ARCH-13** **Drop privileges in the right order and check that it worked.** Give up group privileges before user privileges, and check every return value [2 POS36-C, POS37-C].
14. **ARCH-14** **Hold every dependency of a critical binary to the same standard.** Require that "all transitive dependencies are either free of unsafe constructs or are expert-reviewed for soundness" [7]. A safe-language API may be only a facade: "many system APIs that are exposed via Java are not actually implemented in a safe language" [4 §Safe Languages].
15. **ARCH-15** **Treat duplicated state and confusing lifetimes as bugs.** "If your object lifetimes confuse you, or if your data structure can be modified in three places, or if you have to keep two data structures synchronized at all times, you've probably got a security bug" [14].

## 2. Language choice and safe-coding strategy

1. **LANG-1** **Only complete memory safety stops every exploit type.** "Enforcing Memory Safety stops all memory corruption exploits. For complete Memory Safety, both spatial and temporal errors must be prevented without false negatives" [1 §VI]. Every weaker policy leaves a named gap.
2. **LANG-2** **Write new code in a memory-safe language first.** Vulnerabilities concentrate in new code: "5-year-old code has a 3.4x (using lifetimes from the study) to 7.4x (using lifetimes observed in Android and Chromium) lower vulnerability density than new code". Memory-safety issues fell from 76% of Android vulnerabilities in 2019 to 24% in 2024 [6].
3. **LANG-3** **Prefer interoperability to rewrites.** "We do not need to throw away or rewrite all our existing memory-unsafe code" [6]. Replace components one at a time, so that "security improvements are delivered continuously" [7].
4. **LANG-4** **Make unsafe constructs an opt-in that the compiler enforces.** "Unsafe constructs should cause a compile-time error unless a portion of code is explicitly opted into the unsafe subset" [7 §Safe-by-default, unsafe-by-exception]. In Rust, put `#![forbid(unsafe_code)]` at the crate root unless `unsafe` is justified [19 LANG-UNSAFE][18 safe-unsafe-meaning].
5. **LANG-5** **A safe language can remove the need for a sandbox.** "After removing the now unnecessary sandbox, Chromium's Rust QR code generator is 20 times faster" [6].
6. **LANG-6** **Budget for temporal safety explicitly.** Bounds can be checked cheaply at run time; lifetimes cannot. "For temporal safety, there is no cheap (let alone free) lunch" [7 §Temporal Safety]. Use compile-time lifetime checking, or pay for garbage collection or reference counting.

## 3. Bounds and buffer overflows

1. **SPATIAL-1** **Keep every index and pointer inside its object, checking both bounds.** "Writing to out-of-range pointers or array subscripts can result in a buffer overflow and the execution of arbitrary code", and reading can disclose memory [2 ARR30-C]. A controlled index can point "to any address", not just one element past the end [1 §II-A].
2. **SPATIAL-2** **Check every count or length from the input against the destination's real size.** Heartbleed was an attacker-supplied length passed to `memcpy` [2 ARR38-C]. One buffer had a "fixed size of 32 elements" while the count read from the stream "can have a maximum value of 255" [20 CVE-2022-22675].
3. **SPATIAL-3** *(C/C++)* **Carry the bounds with the pointer.** "Out-of-bounds (OOB) security bugs commonly happen through C-style pointers which have no bounds information associated with them." Use containers and spans in place of a pointer and a separate size, and make raw pointer arithmetic a compile error with `-Wunsafe-buffer-usage` [12].
4. **SPATIAL-4** *(C/C++)* **Replace `memcpy`, `memset` and iterator copies with size-checked range operations.** Note that "`std::ranges::copy` is not bounds-safe (though its name sounds like it should be)". Moving pointer arithmetic into `std::next()` hides the warning and keeps the bug [12].
5. **SPATIAL-5** **Keep pointer arithmetic inside one allocation and in the right units.** Subtracting or comparing pointers into different arrays is undefined [2 ARR36-C]. Adding a byte count to a typed pointer overshoots by the element size [2 ARR39-C]. In Rust, `offset` is undefined behavior when the result is out of bounds, even if never dereferenced [18 safe-unsafe-meaning].
6. **SPATIAL-6** *(C/C++)* **Size string buffers for the data and the terminator, and make sure the terminator is there.** `strncpy()` "does not guarantee that the resulting value is still null-terminated" [2 STR32-C]. Prefer a managed string type [2 STR31-C][3 STR50-CPP].
7. **SPATIAL-7** *(C/C++)* **Never pass untrusted data as a format string.** An attacker who controls it can "view the contents of the stack, view memory content, or write to an arbitrary memory location" [2 FIO30-C]. Compile with `-Werror=format-security` [16].
8. **SPATIAL-8** *(C)* **Validate variable-length array and `alloca` sizes.** An unchecked size "may allow arbitrary code execution or result in stack exhaustion" [2 ARR32-C]. See `HARDEN-7`.
9. **SPATIAL-9** **Check buffers inside a struct separately.** Checkers that track whole allocations miss an overflow from one field into the next: "memory corruption inside objects or structures remains undetected" [1 §VI-B]. Declare flexible arrays as `[]` and build with `-fstrict-flex-arrays=3`, so trailing arrays are checked [16].
10. **SPATIAL-10** **Handle empty input before computing `len - 1`.** A successful `fgets()` can return a string whose first byte is NUL, so `buf[strlen(buf) - 1]` indexes before the buffer [2 FIO37-C].
11. **SPATIAL-11** **A bounds check that guards an unchecked access is trusted code.** Changing `idx < arr.len()` to `idx <= arr.len()` before `get_unchecked(idx)` makes a program unsound, "and yet we only modified safe code" [18 working-with-unsafe].
12. **SPATIAL-12** *(C/C++)* **Give every unchecked-buffer escape hatch a safety comment.** Each one needs "a `// SAFETY:` comment explaining in detail how the code has been evaluated to be safe for all possible input", and reviewers should reject any without [12].
13. **SPATIAL-13** **Bounds checks must stay in release builds.** One exploited overflow had its check only in a debug assertion, and "on release builds, SkAssert calls are compiled out" [20 CVE-2023-6345]. See `HARDEN-3`.
14. **SPATIAL-14** *(Rust)* **Use `get` for untrusted indices.** A panic on attacker input is a denial of service. "A Rust function MUST NOT panic UNLESS its usage conditions have been violated" [19 LANG-LIMIT-PANIC, LANG-ARRINDEXING].

## 4. Lifetimes, use-after-free and ownership

### The bug class

1. **TEMPORAL-1** **Never use or free memory after it is freed.** "Writing memory that has already been freed can additionally lead to the execution of arbitrary code", and "freeing memory multiple times has similar consequences" [2 MEM30-C]. A second `free()` reads attacker-controlled bytes as heap metadata, which gives an arbitrary write [1 §II-A].
2. **TEMPORAL-2** **Read use-after-free as type confusion.** The attacker places a different object in the freed slot, and the old pointer reads it as the old type. An allocator that reuses memory "only among objects of the same type and alignment" blocks that step, though not the dangling use itself [1 §VI-C].
3. **TEMPORAL-3** **A pointer must not outlive its object.** Do not return or store the address of a local [2 DCL30-C]. A lambda that captures by reference and then escapes "will refer to a variable whose lifetime has ended" [3 EXP61-CPP]. Error handlers that free an object but leave pointers to it are a typical cause [1 §II-A].
4. **TEMPORAL-4** *(C++)* **Do not use iterators, references or pointers into a container after it may have reallocated.** Growth of a `std::vector` invalidates them all [3 CTR51-CPP].

### Ownership

5. **TEMPORAL-5** **One owner frees each allocation, once, with the matching allocator.** Passing a pointer to the wrong deallocation function "results in undefined behavior" [3 MEM51-CPP][2 MEM34-C]. Two unrelated smart pointers built from one raw pointer each delete it [3 MEM56-CPP].
6. **TEMPORAL-6** *(C++)* **Keep ownership simple where untrusted input drives lifetimes.** "Keep ownership very simple (avoid raw pointers, avoid `base::Unretained`, single ownership wherever possible)" [14].
7. **TEMPORAL-7** **Across a callback into untrusted code, hold an owning reference and re-check state afterwards.** A script callback can free the object in use or change its type. One fix changed a raw pointer parameter to a reference-counted one [20 CVE-2022-22620]. In another case, "after the final callback, the system does not check whether the window type has changed" [20 CVE-2022-21882].
8. **TEMPORAL-8** **Tie the lifetime of anything you hand out to whoever still points at it.** A wait queue "is still referenced by a pointer in `epoll`, even after the `binder_thread` struct containing it is freed"; the use-after-free "is a symptom of that" [20 CVE-2019-2215].
9. **TEMPORAL-9** **Do not use an address as an identity.** After a free, a new object can get the same address. Use a counter or ID allocator; never expose addresses as identifiers [13][17 §Unique identifiers].
10. **TEMPORAL-10** **Make reference counts saturate or abort on overflow.** A wrapped count reaches zero while references remain. "By trapping atomic wrapping, this class of bug vanishes" [17 §Counter integrity]. Rust's `Arc` aborts for this reason [18 arc-mutex/arc-clone].
11. **TEMPORAL-11** *(C++)* **Use quarantining pointers for non-owning heap pointer fields, and know their limits.** Chromium's `raw_ptr` keeps freed memory quarantined while dangling references exist, and "protects 50% of use-after-free issues against exploitation in Chrome's browser process" [7][13]. It is a mitigation, not ownership.

### Destructors and unwinding

12. **TEMPORAL-12** **Never make memory safety depend on a destructor running.** "Unsafe code cannot rely on destructors to be run in order to be safe"; `mem::forget` is safe code [18 leaking]. The same holds for C++ guards that can be leaked or skipped.
13. **TEMPORAL-13** **Stay memory-safe when an exception or panic unwinds through your code.** Any callback can throw. While an invariant is broken, run only code that cannot unwind, or use a guard that restores a safe state [18 exception-safety]. Code that is not exception-safe "ultimately results in undefined behavior" [3 ERR56-CPP].
14. **TEMPORAL-14** **Treat garbage-collector and reference-tracking logic as memory-safety code.** "A logic bug in the v8 garbage collector means that live objects may remain unmarked and be collected, leading to use-after-free" [20 CVE-2021-37975].

## 5. Integers, conversions and sizes

1. **INT-1** **Check every arithmetic step that produces a size, count or offset.** "The unsigned integer wrap can result in allocating memory of insufficient size" [2 INT30-C]. "Unless you explicitly check an arithmetic operation, it's safest to assume the operation went wrong" [10]. Detecting this at run time kills a bug class [17 §Size calculation overflow detection].
2. **INT-2** **Do not narrow a size.** One driver "multiplies an attacker-controlled integer by 6 and stores the result in a variable of type USHORT" [20 CVE-2020-17087]. A font parser truncated width and height "to 16-bit integers when calculating the bitmap size", then copied using the 32-bit values [20 CVE-2020-15999]. Check that a value fits before any narrowing or sign-changing conversion [2 INT31-C].
3. **INT-3** **Write range checks that cannot overflow and that reject wraparound.** Do not test `i + length >= size`; subtract from the known-larger side [12]. For a start and size pair, reject it when the end is not above the start: one driver "doesn't check if the end is smaller than the start (by wrapping around)" [20 CVE-2023-33107]. Check the lower bound and negative values too [23].
4. **INT-4** **Choose the overflow behavior on purpose: trap, saturate or wrap.** Use a checked cast that crashes on an out-of-range value for sizes and indices, and "do not perform manual conversions using the comparison operators" [11]. In Rust, plain operators wrap silently in release builds, so use `checked_*`, `saturating_*` or `wrapping_*` wherever overflow is possible [19 LANG-ARITH].
5. **INT-5** *(Rust)* **Prefer checked conversions to `as`.** "If a cast triggers some subtle corner case no indication will be given that this occurred" [18 casts]. Debug overflow checks do not cover `as` casts [29 /docs/languages/rust/dynamic-analysis/].
6. **INT-6** **Use explicitly sized integers across process and language boundaries.** "Across any process boundary, use explicitly sized integer types", and range-check values that cross languages [10].
7. **INT-7** *(C/C++)* **Compute allocation sizes from the pointed-to type.** Use `sizeof *p`, not a hand-written type, and overflow-check the count [2 MEM35-C]. In Rust, `Layout::array` does both checks [18 vec/vec-alloc].
8. **INT-8** *(C/C++)* **Use unsigned bytes for binary data.** With a signed `char`, a length byte of 255 becomes -1, and the code performs "a (size_t)-1 memcpy into that buffer" [26 §Use unsigned bytes to represent binary data].
9. **INT-9** **Guard division against zero and against the minimum value divided by -1** [2 INT33-C]. Keep shift counts below the operand's width, and in C cast narrow operands to an unsigned type before shifting [2 INT34-C][26 §Always typecast shifted values].
10. **INT-10** *(GCC/Clang)* **Turn on conversion warnings and fix those that feed sizes and indices first.** "Integer signedness or truncation errors can cause buffer overflows" [16 -Wconversion].

## 6. Uninitialized memory and information leaks

1. **INIT-1** **Initialize every object before reading it.** Reading uninitialized memory can leak earlier stack or heap contents, and "in some cases, these security flaws may allow the execution of arbitrary code" [2 EXP33-C]. Never use it as a source of randomness: compilers "may optimize out the uninitialized variable access completely" [2 EXP33-C].
2. **INIT-2** **Fully initialize anything copied across a trust boundary, including padding.** "Memory copied to userspace must always be fully initialized" [17 §Memory initialization]. "Initializing the members of the structure does not guarantee initialization of the padding bytes" [2 DCL39-C]. One kernel leak let an attacker "leak stale data from various kalloc size classes", which then fed an exploit chain [20 CVE-2020-27950].
3. **INIT-3** *(GCC/Clang)* **Zero-initialize stack variables in production builds.** Use `-ftrivial-auto-var-init=zero`, "to reduce the risk of a logic bug leading to a security vulnerability". Leave it off in builds meant for uninitialized-memory detectors, where it hides the bug [16].
4. **INIT-4** **Never show privileged addresses to a less-privileged reader.** Hash pointers in logs and output [17 §Kernel addresses]. A leaked address defeats layout randomization (`THREAT-6`).
5. **INIT-5** **Wipe memory when it is freed.** Poisoning "frustrates many uninitialized variable attacks, stack content exposures, heap content exposures, and use-after-free attacks" [17 §Memory poisoning].
6. **INIT-6** *(Rust)* **Never treat uninitialized memory as a value, and never make a reference to it.** "It is illegal to construct a reference to uninitialized data" [18 uninitialized]. Initialize a slot with `ptr::write`, not `=`, which would drop the garbage already there [18 unchecked-uninit]. Justify each use of `MaybeUninit` [19 MEM-UNINIT].

## 7. Type confusion, casts and layout

1. **TYPE-1** *(C/C++)* **Do not reinterpret a byte buffer as a wider type.** The cast can be misaligned and breaks aliasing rules, which "can lead to buffer overflow attacks, bypassing security checks, or unexpected execution" [2 EXP39-C, EXP36-C]. Decode values from bytes explicitly [12 §Avoid reinterpret_cast].
2. **TYPE-2** *(C++)* **Do not `memset`, `memcpy` or `memcmp` non-trivial objects.** "Overwriting implementation details of the object representation can lead to code execution vulnerabilities", such as replacing the vtable pointer [3 OOP57-CPP, EXP62-CPP].
3. **TYPE-3** **Check the type tag before reading a tagged union.** One service "doesn't verify this by checking the vt field", so attacker bytes were read as a pointer. Hide union access behind accessors that "always check the vt" [20 CVE-2022-41033].
4. **TYPE-4** **In a JIT, every type assumption needs a run-time guard or an invalidation dependency.** One optimizer "had special-cased the JSCreate operation and then forgot to perform the side-effect modelling" [20 CVE-2020-6418]. When unsure, do not optimize [20 CVE-2021-30632].
5. **TYPE-5** *(Rust)* **Avoid `transmute`; when you must, use it only between types with a defined, identical layout.** "The guardrails here are dental floss" [18 transmutes]. Default-layout types have no guaranteed field order; use `repr(C)` for anything passed to C or viewed as bytes [18 repr-rust, other-reprs].
6. **TYPE-6** *(C)* **Make obsolete C constructs errors.** Implicit declarations and incompatible pointer conversions weaken type checking, and fortification "is of either limited or entirely neutered effect in the presence of implicit function declarations" [16].

## 8. Undefined behavior and compiler assumptions

1. **UB-1** *(C/C++)* **The optimizer assumes undefined behavior never happens, and deletes checks that depend on it.** Signed overflow is the common case: compilers "may simply assume that signed integers never overflow and may generate object code accordingly" [2 INT32-C]. In one example a carry computation vanished: "The additions are gone!" [27 §Compiler Woes]. Check operands before the operation, and do wrapping arithmetic on unsigned types.
2. **UB-2** *(C/C++)* **Check a pointer for null before the first dereference.** After a dereference the compiler may remove a later null check: in one kernel bug it "presumed that dev is not null, and threw away the code" [16 -fno-delete-null-pointer-checks]. Null dereference has led to code execution in kernels [2 EXP34-C].
3. **UB-3** **Honor aliasing promises.** Passing overlapping regions to `memcpy` is undefined; use `memmove` [2 EXP43-C]. In Rust, "transmuting an & to &mut is always Undefined Behavior", and a mutable reference must never alias [18 transmutes, aliasing].
4. **UB-4** *(GCC/Clang)* **Build production code with flags that define the common cases.** The hardening guide recommends `-fno-delete-null-pointer-checks`, `-fno-strict-overflow` and `-fno-strict-aliasing`, because "by default, undefined code can do anything and this is undesirable" [16]. Still fix the code.
5. **UB-5** *(C/C++)* **Return a value on every path of a non-void function.** Otherwise the caller reads whatever was in the return register, even in a password check [2 MSC37-C].
6. **UB-6** *(Rust)* **Know the full list of undefined behavior and allow none of it.** It includes dangling or unaligned pointers, data races, and producing an invalid value such as "a bool that isn't 0 or 1" or "an enum with an invalid discriminant" [18 what-unsafe-does][19 UNSAFE-NOUB]. Avoid `repr(packed)`: references to its fields are unaligned [18 other-reprs].

## 9. Data races and check-then-use races

1. **RACE-1** **Synchronize all shared mutable data.** "Any such data race results in undefined behavior" [2 CON43-C]. Adjacent bit-fields share storage, so one lock must cover all of them [2 CON32-C].
2. **RACE-2** **Copy shared memory before you validate it.** A less-trusted writer can change the bytes between the check and the use. "Make a copy of the data before processing it to avoid time-of-check time-of-use (TOCTOU) bugs" [9].
3. **RACE-3** **Read a shared value once, and use that copy for both the check and the access.** Reloading an index after its bounds check is a memory-safety bug: "It could have changed" [18 races].
4. **RACE-4** **Open files by descriptor, not by repeated path lookup.** Between a check and an open, "an attacker can alter the file between the two accesses, or replace the file with a symbolic or hard link" [2 FIO45-C]. Make the check part of the open [2 POS35-C].
5. **RACE-5** **Model object lifecycle states, and take a reference only in a state that allows it.** Several kernel 0-days took a reference on an object already being destroyed [20 CVE-2021-1048, CVE-2021-0920]. Do not publish an entry to a shared structure before it is validated [20 CVE-2023-33107].
6. **RACE-6** *(C)* **Keep signal handlers to setting a flag.** A handler can interrupt allocator or I/O internals. Handlers should be "as concise as possible—ideally by unconditionally setting a flag and returning" [2 SIG30-C].
7. **RACE-7** **Know which languages guarantee data-race safety.** In Go, "data races can lead to violation of memory safety invariants". On the JVM they cannot, and safe Rust prevents data races at compile time [7].
8. **RACE-8** **Order atomics correctly around a free.** Decrement a reference count with release ordering and acquire before destroying the object [18 arc-mutex/arc-drop]. Use sequentially consistent ordering unless you can prove a weaker one, and test on weakly ordered hardware [18 atomics].
9. **RACE-9** *(Rust)* **Treat a manual `Send` or `Sync` implementation as a proof you must write down.** "Incorrectly implementing Send or Sync can cause Undefined Behavior" [18 send-and-sync]. Avoid them, or justify and document each one [19 LANG-SYNC-TRAITS].

## 10. Rust `unsafe` and other unsafe subsets

1. **UNSAFE-1** **Unsafe code must be sound for every caller.** "No matter what, Safe Rust clients can't cause Undefined Behavior" [18 safe-unsafe-meaning]. If a precondition cannot be enforced inside, mark the function `unsafe` and document its conditions exhaustively [19 LANG-UNSAFE-ENCP]. The same holds for any safe API over unsafe code [7 §Soundness].
2. **UNSAFE-2** **The module, not the `unsafe` block, is the trust boundary.** Safe code that can write a field the unsafe code relies on can break it. "The only bullet-proof way to limit the scope of unsafe code is at the module boundary with privacy" [18 working-with-unsafe].
3. **UNSAFE-3** **Keep unsafe code small, encapsulated, documented and expert-reviewed.** It must be reviewable "with simple local reasoning" [4 §Unsafe Code in Safe Languages]. "Without mandatory review we observed a large number of unnecessary/unsound uses of unsafe constructs" [7].
4. **UNSAFE-4** **Do not trust safe code supplied by the caller.** Unsafe code must stay memory-safe when a comparator, hash or closure is wrong: `BTreeMap` "must be written to be robust against Ord implementations which aren't actually total" [18 safe-unsafe-meaning]. Implement comparison traits so they keep their documented invariants [19 LANG-CMP-INV].
5. **UNSAFE-5** **Bound every lifetime that unsafe code creates.** Dereferencing a raw pointer produces a reference with an unbounded lifetime. "Almost no reference is 'static, so this is probably wrong." Tie it to an input at the function boundary [18 unbounded-lifetimes].
6. **UNSAFE-6** **Declare ownership and variance for raw-pointer types with `PhantomData`.** Wrong variance lets a short-lived reference be stored where a long-lived one is expected: "This is a classic use-after-free bug!" [18 subtyping, phantom-data]
7. **UNSAFE-7** **Pair every `into_raw` with exactly one `from_raw` of the same type.** `from_raw` "MUST ONLY be called on into_rawed values" [19 MEM-INTOFROMRAWONLY, MEM-INTOFROMRAWALWAYS].
8. **UNSAFE-8** **Handle zero sizes explicitly in raw allocation code.** "The raw allocator API has undefined behavior if you pass in 0 for an allocation size", and zero-sized types need an explicit capacity-overflow guard [18 vec/vec-zsts].

## 11. Foreign function interfaces

1. **FFI-1** **Split a binding into a private raw layer and a safe wrapper.** The wrapper "ensures memory safety and security invariants at the Rust level" [19 FFI-SAFEWRAPPING]. Export Rust only through a dedicated C-compatible API [19 FFI-CAPI].
2. **FFI-2** **Use only C-compatible types with the same size and alignment on both sides, and generate the bindings.** "The Rust compiler cannot check if the declaration is correct" [18 ffi]. Use portable `c_*` aliases and tools such as bindgen [19 FFI-CTYPE, FFI-TCONS, FFI-PFTYPE, FFI-AUTOMATE].
3. **FFI-3** **Validate every foreign value before treating it as a type with invalid bit patterns.** Booleans, enums, references and function pointers must arrive as integers or raw pointers and be checked [19 FFI-CKNONROBUST]. "The Rust code MUST NOT accept incoming values of any Rust enum type" [19 FFI-NOENUM].
4. **FFI-4** **Receive foreign pointers as raw pointers and check them before use.** "Pointers MUST be checked to be non-null before any use" [19 FFI-CK-PTR-VALID]. Represent a nullable callback as `Option<extern "C" fn(..)>`, and check function pointers at the boundary [18 ffi][19 FFI-CKFUNPTR].
5. **FFI-5** **Keep the host language's aliasing and mutability rules true across the boundary.** Pointers crossing it "MUST preserve Rust's memory model" [19 FFI-CK-REF-MODEL]. Never pass a pointer derived from an immutable value to code that writes through it.
6. **FFI-6** **One language allocates and frees each object.** "The other language MUST NOT allocate or free the data directly" [19 FFI-MEM-OWNER]. Wrap foreign-owned handles in a type whose destructor calls the foreign release function [19 FFI-MEM-WRAPPING].
7. **FFI-7** **Do not let a panic or exception cross the boundary unplanned.** "A foreign exception entering Rust will cause undefined behavior" [18 ffi]. Code called from foreign code should either be unable to panic or catch the panic [19 FFI-NOPANIC].
8. **FFI-8** **Use a distinct opaque type for each kind of foreign handle,** not `c_void`, so one kind cannot be passed as another [19 FFI-R-OPAQUE][18 ffi].
9. **FFI-9** **When a foreign library calls back from its own threads, synchronize, and unregister before the target object dies.** "No more callbacks are performed by the C library after the respective Rust object gets destroyed" [18 ffi].

## 12. Compiler flags and runtime mitigations

### Applying hardening

1. **HARDEN-1** *(GCC/Clang)* **Set hardening flags explicitly in the build system.** "We recommend explicitly enabling desired compiler flags in your build scripts or build system configuration rather than relying on the toolchain defaults" [16]. The guide's baseline includes `-D_FORTIFY_SOURCE=3`, `-fstack-protector-strong`, `-fstack-clash-protection`, `-fstrict-flex-arrays=3`, `-Wl,-z,relro -Wl,-z,now` and `-Wl,-z,noexecstack`, plus `-fPIE -pie` for executables [16 §TL;DR].
2. **HARDEN-2** **Harden every component at build time, dependencies included.** Hardening "can become impossible to add" to binaries already shipped, and most options protect only the code compiled with them [16 §Background].
3. **HARDEN-3** **Keep security checks in release builds, and crash on a violation.** "`DCHECK`s don't prevent security incidents, because release builds don't have them" [14]. A crash is better than continuing with corrupted memory [7]. The exception is `ARCH-10`.
4. **HARDEN-4** **Test the hardened build, and treat a failure to build or run with these options as a bug** [16]. "A system that works quickly but is vulnerable to adversaries is likely to be unacceptable to users" [16].

### Memory errors

5. **HARDEN-5** *(C++)* **Turn on the standard library's hardened mode in production.** At Google it cost "an average 0.30% performance impact", "uncovered over 1,000 bugs", and cut the baseline segmentation-fault rate by 30% [8]. The flags are `-D_GLIBCXX_ASSERTIONS` or libc++'s fast hardening mode [16].
6. **HARDEN-6** *(GCC/Clang)* **Use `_FORTIFY_SOURCE=3` with optimization in release builds.** It adds bounds checks to C library calls where the compiler knows the object size, and needs at least `-O1`; "at least -O2 is recommended" [16]. Turn it off in sanitizer builds (`VERIFY-2`).
7. **HARDEN-7** **Keep stack canaries on, and know what they miss.** They cost under 1%, but they "do not protect indirect calls and jumps, and they are vulnerable to direct overwrite attacks and information leaks" [1 §III]. Probe large stack allocations with `-fstack-clash-protection`, so one allocation cannot jump the guard page [16].
8. **HARDEN-8** **Harden the allocator.** Check free-list metadata on allocation and free [17 §Heap memory integrity]. See `TEMPORAL-2` for type-segregated reuse.
9. **HARDEN-9** **Treat memory tagging as a probabilistic detector.** With 16 tags, "there is a non-trivial chance (6.25%) that dangling pointers are not marked as invalid" [7 §MTE].

### Code and control flow

10. **HARDEN-10** **No memory is both writable and executable.** "A page can be either writable or executable, but not both"; hardware enforces it at no cost [1 §II-B, Table II]. Just-in-time compilers break this, so make any writable window explicit and short [17 §Strict kernel memory permissions].
11. **HARDEN-11** **Non-executable data does not stop code reuse.** It "does not protect against code reuse attacks like ROP" [1 §III]. Defend earlier, with memory safety or control-flow integrity.
12. **HARDEN-12** **Randomize every region.** Address randomization "can always be bypassed if not all code and data sections are randomized" [1 §V-A]. Build position-independent executables; the cost is "negligible on 64-bit architectures" [16].
13. **HARDEN-13** **Keep code pointers that never change in read-only memory.** Full RELRO is required: "partial RELRO is not sufficient" against overwrites of the global offset table [16]. Make function-pointer tables `const` and mark set-once variables read-only after initialization [17].
14. **HARDEN-14** **Enable hardware control-flow protection.** Use `-fcf-protection=full` on x86_64 and `-mbranch-protection=standard` on AArch64 [16]. For returns, a shadow stack beats any static target set, because "at run-time, there is always exactly one correct target of a function return" [1 §VIII-B].
15. **HARDEN-15** *(GCC/Clang)* **Clear scratch registers on return.** `-fzero-call-used-regs=used-gpr` "reduced the number of unique ROP gadgets in the resulting image by about 20%" in the kernel. "This is a mitigation, not a barrier" [16].
16. **HARDEN-16** **Limit what the process can load.** Link with `--as-needed`, mark non-plugin libraries `nodlopen`, and avoid run-time search paths in release binaries, where an attacker "may be able to supply their own shared files" [16].

### Rust builds

17. **HARDEN-17** *(Rust)* **Keep overflow checks and debug assertions on in development and test profiles** [19 DENV-CARGO-OPTS]. Build with a stable toolchain [19 DENV-STABLE].

## 13. Secrets, constant time and randomness

### Timing

1. **SECRET-1** **Define constant time as timing that does not depend on secrets, and list what is public.** "Execution time may still vary, but not in a way that can be traced back to any kind of value that you wish to keep secret." Lengths usually may leak: "only the contents are protected" [27].
2. **SECRET-2** **Compare secrets with a constant-time function.** "String comparisons performed byte-per-byte may be exploited in timing attacks, for example in order to forge MACs" [26].
3. **SECRET-3** **Do not branch on secret data.** "If a conditional branching (if, switch, while, for) depends on secret data then the code executed as well as its execution time depend on the secret data as well" [26]. Compute both results and select with a mask [27].
4. **SECRET-4** **Do not index memory with secret data.** "Cache-based leaks have been successfully leveraged to retrieve secret keys" from RSA and AES, including by code in another virtual machine [27 §Execution Model]. Use bitwise logic, or read every entry and keep one with a masked copy.
5. **SECRET-5** **Bound loops by public values.** One implementation "leaked the logarithm of the (secret) ECDSA nonce, which could be used to steal the private key of a TLS server" [26 §Avoid secret-dependent loop bounds].
6. **SECRET-6** **Know which instructions take variable time.** Division can "trigger a faster code path when the divisor and/or the dividend is small" [27]. Multiplication is variable-time on some CPUs, such as the ARM9 [27], and compiler helper routines for wide multiplies may exit early [28].
7. **SECRET-7** **Check the machine code.** "Timing is not considered observable behavior" in C or Rust, so the compiler may turn a mask into a branch [26]. Pass full-width control words, not booleans [27 §Compiler Woes].
8. **SECRET-8** **When checking data derived from a secret, read everything and decide once.** "If any of the bytes does not have the right value, the good flag is cleared, but processing continues" [27 §CBC padding].

### Memory and randomness

9. **SECRET-9** **Wipe secrets with a function the compiler cannot remove.** A `memset` on a buffer that is never read again is deleted: one compiler "suppressed the memset" in Tor. Use `explicit_bzero`, `memset_s` or `SecureZeroMemory`, and check the result, since workarounds "can still be optimized out" [26].
10. **SECRET-10** **Wipe before the secret goes out of scope, and know where wiping cannot reach.** Memory can be read after a crash dump, from swap, or through a bug. "There's virtually no way to reliably clean secret data in garbage-collected languages" [26 §Clean memory of secret data].
11. **SECRET-11** *(Rust)* **Do not rely on `Drop` alone to erase a secret.** Erasure "MUST NOT rely only on the Drop trait implementation", because leaks, cycles and aborts skip destructors [19 LANG-DROP-SEC].
12. **SECRET-12** **Take secret randomness from the operating system, and check every return value.** "Leaking just one bit of each random number in the DSA will reveal a private key astonishingly quickly" [26 §Use strong randomness]. Never use `rand()` or a fixed seed [2 MSC30-C, MSC32-C].
13. **SECRET-13** **Make insecure functions hard to call.** "Design your APIs so that using an insecure function is always a bit scary", and keep raw primitives in a separate layer from safe high-level operations [26].

## 14. Fuzzing, sanitizers, review and patching

### Fuzzing

1. **VERIFY-1** **Fuzz every parser of untrusted input.** "Write fuzzers for any data that your code is ingesting" [14]. Fuzzing "has proven itself a must-have tool for memory-unsafe languages" [29 /docs/fuzzing/].
2. **VERIFY-2** **Fuzz with sanitizers, because many memory errors do not crash.** An out-of-bounds write can land in memory that "is still mapped in the process" [29 /docs/fuzzing/c-cpp/libfuzzer/]. Sanitizers cost "a 2× to 4× slowdown" and are for test builds, not production [16 §Sanitizers]. Disable `_FORTIFY_SOURCE` in these builds (`HARDEN-6`): it is "source fortification that is incompatible with ASan" [29 /docs/fuzzing/c-cpp/aflpp/].
3. **VERIFY-3** **Write harnesses that take any input, never exit, and keep no state between runs.** "A harness must handle all kinds of input, such as empty, huge, or malformed inputs". Global state "can cause test cases to crash only during fuzzing but not afterwards" [29 /docs/fuzzing/techniques/writing-harnesses/].
4. **VERIFY-4** **Measure coverage after each campaign and remove what blocks the fuzzer.** "A magic value check ... may be hard for a fuzzer to overcome" [29 /docs/fuzzing/c-cpp/techniques/coverage-analysis/]. Seed with real inputs and a dictionary. Skip checksums only in fuzzing builds: "carelessly skipping checks can lead to false positives" [29 /docs/fuzzing/c-cpp/techniques/obstacles/].
5. **VERIFY-5** **Add property and differential checks to catch bugs that do not crash.** Examples are a round trip, `decode(encode(x)) == x`, and comparing two implementations [29 /docs/fuzzing/].
6. **VERIFY-6** **Fuzz continuously and keep every crash as a regression input.** "Ideally, you fuzz continuously on dedicated servers and in the continuous integration service you are already using" [29 /docs/fuzzing/techniques/faq/].
7. **VERIFY-7** **Do not take bug finding as assurance.** "Bug finding alone does not achieve an acceptable level of assurance for memory-unsafe languages." One exploited bug "was missed despite high fuzzing coverage (97.55% in the relevant file)" [7]. Shadow-memory detectors miss a use-after-free once the memory is reallocated [1 §VI-C].
8. **VERIFY-8** **When a fuzzer misses an exploited bug, change the fuzzer.** One kernel leak "could have been found by fuzzing if the fuzzer was set up to discover uninitialized memory" [20 CVE-2020-27950].

### Patching

9. **VERIFY-9** **Fix the root cause, not the proof of concept.** Vendors often "block only the path that is shown in the proof-of-concept or exploit sample, rather than fixing the vulnerability as a whole" [21]. "At least half of the 0-days we've seen in the first six months of 2022 could have been prevented with more comprehensive patching and regression tests" [23].
10. **VERIFY-10** **After every security fix, look for variants.** "17 out of 41 of the 0-days discovered in-the-wild in 2022 are variants of previously public vulnerabilities" [24]. Search for the same pattern elsewhere, and if you ship a fork, track upstream fixes [20 CVE-2023-33107, CVE-2021-1048].

### Static checks and review

11. **VERIFY-11** *(GCC/Clang)* **Use warnings as a free security tool.** They "do not have an impact on the binary code generated" [16]. Use blanket `-Werror` only in development; ship only selective `-Werror=` flags [16].
12. **VERIFY-12** **Check the error return of every library call.** Unchecked failures "could even allow an attacker to run arbitrary code" [2 ERR33-C]. An unchecked allocation failure becomes an attacker-controlled offset from null [3 MEM52-CPP].
13. **VERIFY-13** *(Rust)* **Run tests and fuzz corpora under Miri and the sanitizers.** "One may open a gate to the unsafe world and introduce all the well-known vulnerabilities like use-after-free and reading of uninitialized memory" [29 /docs/languages/rust/dynamic-analysis/].
14. **VERIFY-14** *(Rust)* **Pin and audit dependencies.** Track `Cargo.lock` in version control and run `cargo-audit` [19 DENV-CARGO-LOCK, LIBS-AUDIT].

---

## Checklist for one review

1. Map the trust boundaries. For each component, count untrusted input, unsafe language and high privilege (`ARCH-1`).
2. For each parser of untrusted input, ask whether it can move to a safe language or a sandbox (`LANG-2`, `ARCH-2`), and whether it is fuzzed with sanitizers (`VERIFY-1`, `VERIFY-2`).
3. For each message from a less-privileged peer, check sizes, offsets and types (`ARCH-7`, `INT-1`, `TYPE-3`), and copy shared memory first (`RACE-2`).
4. In unsafe code, check every size computation (`INT-1` to `INT-3`), every bound (`SPATIAL-1`, `SPATIAL-2`), every lifetime (`TEMPORAL-3`, `TEMPORAL-7`) and every value copied out (`INIT-2`).
5. For Rust `unsafe` and FFI, check the module-level soundness argument (`UNSAFE-1`, `UNSAFE-2`) and the boundary types (`FFI-2` to `FFI-4`).
6. For secrets, check comparison, branches, table lookups and wiping (`SECRET-2` to `SECRET-4`, `SECRET-9`).
7. Check that the build sets the hardening baseline and that the hardened build is the one tested (`HARDEN-1`, `HARDEN-4`).
8. For each fixed bug, confirm the root cause is fixed, a regression test exists, and variants were searched (`VERIFY-9`, `VERIFY-10`).

---

## References

**Model**

1. László Szekeres, Mathias Payer, Tao Wei and Dawn Song, "SoK: Eternal War in Memory" (IEEE S&P 2013): https://doi.org/10.1109/SP.2013.13. Authors' copy: https://people.eecs.berkeley.edu/~dawnsong/papers/Oakland13-SoK-CR.pdf. Cited by section number.

**SEI CERT**

2. SEI CERT C Coding Standard: https://cmu-sei.github.io/secure-coding-standards/sei-cert-c-coding-standard/. Cited by rule ID, e.g. INT30-C.
3. SEI CERT C++ Coding Standard: https://cmu-sei.github.io/secure-coding-standards/sei-cert-cpp-coding-standard/. Cited by rule ID, e.g. CTR50-CPP.

**Chromium and Google**

4. "The Rule Of 2": https://chromium.googlesource.com/chromium/src/+/main/docs/security/rule-of-2.md
5. "Memory safety" (Chromium Security): https://www.chromium.org/Home/chromium-security/memory-safety/
6. Jeff Vander Stoep and Alex Rebert, "Eliminating Memory Safety Vulnerabilities at the Source" (2024-09-25): https://security.googleblog.com/2024/09/eliminating-memory-safety-vulnerabilities-Android.html
7. Alex Rebert and Christoph Kern, "Secure by Design: Google's Perspective on Memory Safety" (technical report, 2024-03-04): https://research.google/pubs/secure-by-design-googles-perspective-on-memory-safety/. Summary: https://security.googleblog.com/2024/03/secure-by-design-googles-perspective-on.html
8. Alex Rebert, Max Shavrick and Kinuko Yasuda, "Retrofitting spatial safety to hundreds of millions of lines of C++" (2024-11-15): https://security.googleblog.com/2024/11/retrofitting-spatial-safety-to-hundreds.html
9. "Mojo 'Style' Guide" (IPC security): https://chromium.googlesource.com/chromium/src/+/main/docs/security/mojo.md
10. "Integer Semantics, Unsafety, And You": https://chromium.googlesource.com/chromium/src/+/main/docs/security/integer-semantics.md
11. `base/numerics` README: https://chromium.googlesource.com/chromium/src/+/main/base/numerics/README.md
12. "The Unsafe Buffers Clang plugin": https://chromium.googlesource.com/chromium/src/+/main/docs/unsafe_buffers.md
13. "`raw_ptr<T>` (aka. MiraclePtr, aka. BackupRefPtr, aka. BRP)": https://chromium.googlesource.com/chromium/src/+/main/base/memory/raw_ptr.md
14. "Top security things for Chromies to remember": https://chromium.googlesource.com/chromium/src/+/main/docs/security/checklist.md
15. "The browser process should not handle messages from web content": https://chromium.googlesource.com/chromium/src/+/main/docs/security/handling-messages-from-web-content.md

**Hardening**

16. OpenSSF Best Practices Working Group, "Compiler Options Hardening Guide for C and C++" (2026-08-20): https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++.html. Cited by section or option name.
17. "Kernel Self-Protection", Linux kernel documentation: https://docs.kernel.org/security/self-protection.html

**Rust**

18. *The Rustonomicon*: https://doc.rust-lang.org/nomicon/. Cited by page name, e.g. leaking → `leaking.html`, vec/vec-alloc → `vec/vec-alloc.html`.
19. ANSSI, *Secure Rust Guidelines*: https://anssi-fr.github.io/rust-guide/. Cited by rule ID, e.g. FFI-NOENUM; all IDs appear in https://anssi-fr.github.io/rust-guide/print.html.

**Project Zero and Threat Analysis Group**

20. "0-days In-the-Wild" root cause analyses: https://googleprojectzero.github.io/0days-in-the-wild/rca.html. Cited by CVE; each analysis is at `0day-RCAs/<year>/CVE-<year>-<number>.html` under that site.
21. Maddie Stone, "Déjà vu-lnerability: A Year in Review of 0-days Exploited In-The-Wild in 2020" (2021-02-03): https://projectzero.google/2021/02/deja-vu-lnerability.html
22. Maddie Stone, "The More You Know, The More You Know You Don't Know" (2021 review, 2022-04-19): https://projectzero.google/2022/04/the-more-you-know-more-you-know-you.html
23. Maddie Stone, "2022 0-day In-the-Wild Exploitation…so far" (2022-06-30): https://projectzero.google/2022/06/2022-0-day-in-wild-exploitationso-far.html
24. Maddie Stone, "The Ups and Downs of 0-days: A Year in Review of 0-days Exploited In-the-Wild in 2022" (2023-07-27): https://security.googleblog.com/2023/07/the-ups-and-downs-of-0-days-year-in.html
25. Google TAG and Mandiant, "We're All in this Together: A Year in Review of Zero-Days Exploited In-the-Wild in 2023" (2024-03): https://storage.googleapis.com/gweb-uniblog-publish-prod/documents/Year_in_Review_of_ZeroDays.pdf

**Secret handling**

26. Jean-Philippe Aumasson, "Cryptocoding": https://github.com/veorq/cryptocoding. Cited by section heading.
27. Thomas Pornin, "Constant-Time Crypto" (BearSSL): https://www.bearssl.org/constanttime.html
28. Thomas Pornin, "Constant-Time Mul" (BearSSL): https://www.bearssl.org/ctmul.html

**Testing**

29. Trail of Bits, *Testing Handbook*: https://appsec.guide/. Cited by path, e.g. /docs/fuzzing/ → https://appsec.guide/docs/fuzzing/.
