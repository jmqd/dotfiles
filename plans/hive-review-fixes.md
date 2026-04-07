# hive orchestrator review fixes plan

## Status

Proposed follow-up plan for the review of `HEAD~10..HEAD`.

## Scope

Stabilize the new `hive-orchestrator` work before adding more features.

Primary files in scope:

- `home/.pi/agent/extensions/hive-orchestrator/index.ts`
- `home/.pi/agent/extensions/hive-orchestrator/orchestrator.ts`
- `home/.pi/agent/extensions/hive-orchestrator/core.ts`
- `home/.pi/agent/extensions/hive-orchestrator/README.md`
- `home/.pi/agent/extensions/hive-orchestrator/skills/hive-swarm/references/runtime-roadmap.md`

## Objective

Address the correctness and operator-safety issues found in review, with tests first where practical, then align the docs with the actual runtime behavior.

## Why hive is still appropriate

This work is still a good fit for `hive`, but only with conservative concurrency.
The code paths overlap heavily in the orchestrator runtime and queue state, so the first phase should optimize for correctness, not parallelism.

Recommended initial concurrency for `/hive-run`: **1 worker**.

If the planner finds a clean split after the queue transaction fix lands, it may expand to **2 workers max**.
Until then, avoid overlapping orchestrator mutations.

## Must fix

### 1. Queue mutations must be transactional

Problem:

- `init` / `enqueue` / `poll` / `tick` currently follow a read-modify-write shape.
- only the final write is serialized
- overlapping actions can load the same old queue and clobber each other

Required fix:

- lock the entire queue read-modify-write transaction per queue file
- or add optimistic retry with versioning
- prefer a single queue transaction helper around `withFileMutationQueue(...)`

Acceptance criteria:

- overlapping queue updates do not lose progress, dispatches, or merged state
- `init`, `enqueue`, `poll`, and `tick` all use the same transaction boundary

### 2. Integration must not claim success from tree equality alone

Problem:

- `integrateTask()` currently has a no-op path that can mark a task `merged` when the worker tree matches `HEAD`, even if the worker commit was never actually integrated

Required fix:

- only treat a task as already integrated if the worker commit is actually contained on the integration branch
- use an ancestry/containment check instead of tree equality as the success condition
- if the trees match but the commit is not contained, continue normal integration flow instead of claiming success

Acceptance criteria:

- contained commit -> task may be marked merged
- tree-equal but non-contained commit -> task is not falsely marked merged

### 3. Scheduler state must remain retryable and not strand an agent

Problems:

- transient `launchWorker()` failures currently poison a task by marking it `failed`
- agent occupancy treats `done` as blocking the agent, even when nothing is still running

Required fix:

- launch-time control-plane failures should leave tasks retryable
- agent availability should depend on active worker execution, not `done`/`blocked`/`failed`
- same-agent follow-on work must be dispatchable once the prior worker is no longer running

Acceptance criteria:

- transient launch failure keeps the task dispatchable later
- done-but-not-yet-integrated work does not permanently reserve an agent slot
- same-agent follow-up tasks can dispatch when no worker is running

## Should fix

### 4. Missing worker artifacts must not synthesize `running`

Problem:

- polling currently infers `running` when there is no pid, no exit code, and no status

Required fix:

- preserve prior task state unless there is positive evidence of worker activity
- treat missing artifacts as missing evidence, not active work

### 5. Worker state storage must be unique per repo root

Problem:

- shared worker state currently keys off `path.basename(repoRoot)`
- unrelated repos with the same basename can collide

Required fix:

- use a stable unique key derived from the full repo root
- keep it readable if convenient, but uniqueness matters more than prettiness

### 6. API/runtime behavior should match the contract

Required fixes:

- make `dispatchLimit` integer-shaped at the schema boundary
- make `/hive-loop` use the persisted queue poll interval by default when no argument is supplied
- keep argument-supplied interval as the explicit override

### 7. Docs should match the implementation

Required clarifications:

- update `runtime-roadmap.md` now that `/hive-loop` and `/hive-stop` exist
- distinguish repo-local orchestrator files under `.hive/orchestrator/*` from worker `.hive/*` artifacts in hive-managed worker worktrees/state
- clarify that `.hive/orchestrator/planning-notes.md` is authored by the planning workflow, not maintained as orchestrator runtime state

## Test-first work to add

Add or expand tests for:

1. queue transaction safety
   - overlapping `enqueue` / `poll` / `tick` updates do not lose data
2. integration containment
   - contained commit vs tree-equal non-contained commit
3. scheduler/state-machine behavior
   - transient launch failure remains retryable
   - same-agent follow-on task dispatches once no worker is running
   - missing worker artifacts do not become synthetic `running`
4. parser/runtime edge cases where cheap to cover
   - `renderPromptTemplate` slice edge cases
   - `loadWorkerSnapshot` malformed JSON and nonnumeric pid/exit behavior
   - `syncTaskWithWorker` no-evidence / no-change timestamp behavior
   - `createAutoFollowUpTask` dependency rewrite coverage

## Ordered implementation plan

### Phase 1: characterization tests

Add failing or characterization tests for the current risky behavior before changing runtime logic where practical.

### Phase 2: queue transaction helper

Add a narrow helper that:

- acquires the queue mutation lock
- loads the freshest queue state inside the lock
- applies the mutation
- writes queue/progress artifacts from that locked view

Then migrate:

- `init`
- `enqueue`
- `poll`
- `tick`

### Phase 3: scheduler and polling fixes

Update orchestrator state handling so that:

- missing worker evidence does not synthesize `running`
- active worker execution is what blocks an agent
- launch failures stay retryable instead of becoming terminal failures

### Phase 4: integration containment fix

Update `integrateTask()` so that "already integrated" means commit containment, not just tree equality.

### Phase 5: unique repo key for worker state

Make worker storage paths unique to the full repo root and update tests accordingly.

### Phase 6: API behavior alignment

- enforce integer `dispatchLimit`
- use the queue poll interval as the default for `/hive-loop`

### Phase 7: docs cleanup

Update README and skill/reference docs to match the final behavior.

## Suggested worker split

Default recommendation: **start with 1 worker only**.

If `/hive-run` decides to use more than one worker, it should not do so until the queue transaction fix is merged.

A reasonable staged split after that point would be:

### Worker A

- add characterization tests
- implement queue transaction helper
- migrate queue actions to the helper
- verify queue mutation safety

### Worker B

- integration containment fix
- scheduler/polling retryability fixes
- unique repo storage key
- API/docs cleanup if the merge surface is small enough

If the overlap still looks high after inspection, keep all of this on one worker.

## Commit boundaries

1. `pi: add hive orchestrator regression tests`
2. `pi: make hive queue mutations transactional`
3. `pi: fix hive scheduler retryability and agent availability`
4. `pi: require commit containment for hive integration`
5. `pi: key hive worker state by repo root`
6. `pi: align hive loop and dispatch api behavior`
7. `pi: update hive orchestrator docs`

If the transaction helper is tiny, commits 2 and 3 can be combined.

## Verification

Focused checks:

- `node --test home/.pi/agent/extensions/hive-orchestrator/core.test.ts home/.pi/agent/extensions/hive-orchestrator/orchestrator.test.ts`
- `node --check home/.pi/agent/extensions/hive-orchestrator/index.ts`
- `nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).hive-orchestrator-tests`

Final repo-level check:

- `just check`

Manual smoke cases:

- initialize a queue and enqueue tasks
- simulate a transient worker launch failure and confirm the task remains retryable
- poll a missing/nonexistent worker state and confirm it does not become synthetic `running`
- verify the already-integrated branch distinguishes contained vs merely tree-equal worker commits
- verify `/hive-loop` defaults to queue `pollIntervalSeconds` when no override is passed

## Notes for `/hive-run`

When using this plan with `/hive-run`, the planner should:

- read this file first
- keep concurrency conservative
- prioritize must-fix items before should-fix items
- write a distilled execution summary to `.hive/orchestrator/planning-notes.md`
- avoid spawning overlapping workers against the same queue logic until transaction safety is fixed
