# Candidate TODOs

Candidate ideas for taking this dotfiles and workstation setup in materially new directions. These are ideas to evaluate, not pre-approved implementation work.

For each candidate, decide:

- What genuinely new capability does it add?
- What is the smallest reversible experiment?
- How would it be verified under failure, not only the happy path?
- What ongoing maintenance and recovery burden would it create?

## Candidates

### 1. Jujutsu + Mergiraf: change the physics of version control

- [ ] Evaluate Jujutsu and Mergiraf in a disposable colocated Git repository.

Use Jujutsu for mutable commits, stable change IDs, an operation log, first-class conflicts, and revset-driven history manipulation while retaining compatibility with Git and GitHub. Add Mergiraf as the syntax-aware merge engine, giving the existing Difftastic and ast-grep workflow a structural counterpart on the write path.

Smallest experiment: install `jj` and `mergiraf` through Home Manager, use a colocated `.jj`/`.git` workspace in one non-critical repository, and exercise normal editing, rebasing, conflict resolution, and GitHub publication.

### 2. `rr`: time-travel debugging for real failures

- [ ] Evaluate `rr` on the x86_64 Linux host.

Record an intermittent Rust or native-process failure once, then replay the exact execution under GDB with reverse execution and watchpoints. Preserve portable traces as bug artifacts so a difficult failure can be investigated backward from the corruption instead of repeatedly reproduced.

Smallest experiment: record and replay a deterministic `flow` test or another small Rust binary, then deliberately introduce a fault and locate it with `reverse-continue`.

### 3. Model checking as part of normal development

- [ ] Compare Stateright, TLA+/TLC, and Apalache for distributed-system design work.

Make distributed protocols ship with executable invariants before implementation. Semaphore, consensus, retry, failover, and OpenRaft-related designs could exhaustively explore crashes, partitions, stale leaders, and unlucky interleavings that conventional tests are unlikely to cover.

Smallest experiment: model one bounded semaphore or lease protocol, encode its safety invariants, and add the model check as a focused flake check.

### 4. An AI-agent blast chamber

- [ ] Prototype capability-limited, disposable execution environments for coding agents.

Run Claude, Codex, OMP, and Oracle inside disposable MicroVM or Bubblewrap environments with copy-on-write worktrees, no ambient credentials, explicit filesystem capabilities, and an egress allowlist. Fan the same problem out to multiple agents, export only patches and transcripts, and compare independent solutions without trusting any agent's execution environment.

Smallest experiment: sandbox one agent against a throwaway repository with read-only source, one writable worktree, no home-directory access, and network access disabled after dependency realization.

### 5. An "erase your darlings" NixOS machine

- [ ] Evaluate Impermanence and disko for `jmws`.

Reset the root filesystem on every boot and retain only explicitly declared state. Every reboot would continuously test that the flake, rather than accumulated filesystem archaeology, is sufficient to reconstruct the machine.

Smallest experiment: build the persistence policy in a VM, repeatedly reboot it, and verify machine identity, services, secrets, databases, logs, and user state before considering bare metal.

### 6. A personal bare-metal rescue plane

- [ ] Build a flake-defined rescue environment design.

Produce a kexec, PXE, or USB NixOS image containing disk recovery tools, forensic tooling, YubiKey and SOPS access, networking, and `nixos-anywhere`. A sick or blank machine could boot directly into a trusted personal operating environment and reinstall itself from the same source that defines the normal host.

Smallest experiment: build and boot a custom rescue ISO or VM image, then use it to inspect and reinstall a disposable virtual disk from the repository flake.

### 7. Secrets that know what booted

- [ ] Investigate measured-boot-gated service credentials.

Combine Lanzaboote Secure Boot, TPM2 measurements, and systemd encrypted credentials so sensitive service material is released only after an approved boot chain. This moves from "the configuration is signed" to "the machine can cryptographically demonstrate what booted before receiving secrets."

Smallest experiment: use a VM or spare NixOS machine to seal a non-critical credential to a measured boot policy, prove that the expected generation unlocks it, and prove that a changed boot chain does not.

### 8. A personal short-lived SSH PKI

- [ ] Evaluate Smallstep `step-ca` for user and host SSH certificates.

Sign every host key and issue short-lived user certificates after hardware-backed authentication. Static `authorized_keys`, unmanaged host keys, and `known_hosts` trust-on-first-use could be replaced by identity, policy, and expiration.

Smallest experiment: run an isolated CA, enroll one test host, issue a short-lived user certificate, verify host-certificate trust, and rehearse CA loss and key rotation before touching normal SSH access.

### 9. Interaction grammar compiled into hardware

- [ ] Evaluate QMK or ZMK firmware management through the flake.

Encode the custom `i/j/k/l`, tmux, and Emacs navigation model at the keyboard layer so the same controls work in firmware menus, rescue shells, and otherwise unconfigured hosts. Add probe-rs or another hardware-in-the-loop path for reproducible builds, flashing, logs, and key-matrix assertions.

Smallest experiment: reproduce the current keyboard layout as versioned firmware, build it through Nix, and validate one non-destructive navigation layer on spare or recoverable hardware.

### 10. Make GitHub a mirror rather than an authority

- [ ] Evaluate Radicle for selected repositories.

Seed dotfiles or private tooling through Radicle's peer-to-peer Git protocol, signed repository state, and offline collaboration model. GitHub could remain a public convenience mirror while the canonical personal network stays locally owned and cryptographically identified.

Smallest experiment: publish a non-sensitive test repository through two local Radicle nodes, work offline, exchange a signed patch, and verify recovery after deleting one node's state.

### 11. Test build reproducibility instead of assuming it

- [ ] Prototype independent rebuild comparison and provenance attestations.

Have two independent machines build selected derivations, compare their NAR hashes, and publish signed in-toto or Rekor attestations for matches. When outputs disagree, feed them to `diffoscope` rather than silently trusting a binary cache or assuming Nix implies bit-for-bit reproducibility.

Smallest experiment: independently build the small `flow` derivation on two Linux builders, compare outputs, and create a local signed attestation without publishing metadata externally.

### 12. Performance assertions written in SQL

- [ ] Evaluate Perfetto Trace Processor and PerfettoSQL.

Collect perf, ftrace, and eBPF data into Perfetto, then check in SQL queries as executable performance specifications. Properties such as startup off-CPU time, filesystem synchronization count, scheduler latency, or unexpected process creation could become reviewable tests rather than screenshots.

Smallest experiment: capture one `flow` command, write a query that extracts a stable behavioral metric, and determine whether it is deterministic enough to guard as a regression check.

### 13. A hostile digital twin of the workstation

- [ ] Design failure-injection tests for bootstrap and activation paths.

Use NixOS VM or MicroVM tests to run bootstrap, activation, and recovery under injected failures: offline registry, full disk, read-only home, absent YubiKey, permission denial, interrupted activation, stale generation, and failed service startup. Recovery documentation would become an executable chaos suite rather than prose first exercised during an emergency.

Smallest experiment: model one recent real failure—disk exhaustion during a Nix build—and assert that the activation or wrapper path fails safely with an actionable diagnostic and no partial state transition.

### 14. Hardware-gated, automatically rekeyed secrets

- [ ] Evaluate age-plugin-yubikey with agenix-rekey or the existing SOPS design.

Keep master recipients on two hardware keys, derive host recipients from declared inventory, and automatically re-encrypt relevant secrets when machines are added or retired. Require physical touch for normal decryptions while maintaining and regularly testing a separate recovery-key ceremony.

Smallest experiment: encrypt one non-critical test secret to a primary YubiKey, backup YubiKey, and offline recovery recipient; then rehearse host enrollment, rekeying, primary-key loss, and recovery.

### 15. A personal software transparency ledger

- [ ] Prototype signed, append-only configuration history.

Sign flake lock updates, Home Manager and NixOS activations, custom binary pins, and security-policy changes, then append the attestations to Rekor or a minimal self-hosted transparency log. The useful property is detectable rollback: a host could reject an apparently valid configuration that has been historically superseded.

Smallest experiment: log local signed statements for several disposable Home Manager generations, verify inclusion and ordering, and test detection of an attempted rollback without publishing private metadata.

## Suggested evaluation order

1. Jujutsu + Mergiraf: largest immediate workflow change with a small reversible trial.
2. Model checking: strongest correctness experiment for distributed-system work.
3. AI-agent blast chamber: most specific to the current multi-agent setup.
4. Bare-metal rescue plane: makes the repository useful when the normal system is unavailable.
5. Hardware-managed keyboard firmware: a bounded, unusual project with an immediately tangible result.
6. Hostile digital twin: converts operational assumptions into executable evidence.
7. Impermanence and measured boot: high-value architectural changes after recovery paths are proven.

## References

1. [Jujutsu Git compatibility](https://docs.jj-vcs.dev/latest/git-compatibility/), [Jujutsu revsets](https://docs.jj-vcs.dev/latest/revsets/), and [Mergiraf](https://mergiraf.org/)
2. [`rr` record/replay debugger](https://rr-project.org/) and [`rr` usage](https://github.com/rr-debugger/rr/wiki/Usage)
3. [Stateright](https://www.stateright.rs/), [TLA+](https://lamport.org/tla/tla.html), and [Apalache](https://apalache-mc.org/)
4. [microvm.nix](https://microvm-nix.github.io/microvm.nix/) and [Bubblewrap](https://github.com/containers/bubblewrap)
5. [Impermanence](https://github.com/nix-community/impermanence) and [disko](https://github.com/nix-community/disko)
6. [NixOS netboot and kexec](https://nixos.org/manual/nixos/stable/#sec-booting-from-pxe) and [nixos-anywhere](https://nix-community.github.io/nixos-anywhere/)
7. [Lanzaboote](https://github.com/nix-community/lanzaboote), [systemd credentials](https://systemd.io/CREDENTIALS/), and [Keylime](https://keylime.dev/)
8. [Smallstep SSH certificate tutorial](https://smallstep.com/docs/tutorials/ssh-certificate-login/)
9. [QMK](https://docs.qmk.fm/), [ZMK](https://zmk.dev/docs), and [probe-rs](https://probe.rs/docs/tools/probe-rs/)
10. [Radicle protocol](https://radicle.dev/guides/protocol) and [Radicle user guide](https://radicle.dev/guides/user)
11. [in-toto](https://in-toto.io/) and [Rekor transparency log](https://docs.sigstore.dev/logging/overview/)
12. [Perfetto Trace Processor](https://perfetto.dev/docs/analysis/getting-started) and [PerfettoSQL](https://perfetto.dev/docs/analysis/perfetto-sql-getting-started)
13. [NixOS tests](https://nixos.org/manual/nixos/stable/#sec-nixos-tests)
14. [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey) and [agenix-rekey](https://github.com/oddlama/agenix-rekey)
