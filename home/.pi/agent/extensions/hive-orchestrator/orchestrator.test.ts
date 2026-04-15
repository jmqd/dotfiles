import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { WorkerSnapshot } from "./core.ts";
import {
	DEFAULT_ORCHESTRATOR_POLL_INTERVAL_SECONDS,
	addTasksToQueue,
	applyTaskDispatchFailure,
	applyTaskIntegrationResult,
	checkWorkerCommitAlreadyIntegrated,
	createAutoFollowUpTask,
	createOrchestratorQueue,
	deriveDeterministicFixupCommands,
	getOrchestratorPaths,
	isTaskReadyForDispatch,
	limitDispatchTasks,
	loadPersistedHiveLoopIntervalSeconds,
	loadQueue,
	renderOrchestratorPlan,
	renderQueueSummary,
	renderQueueWidget,
	resolveHiveLoopInterval,
	resolveHiveLoopIntervalSeconds,
	shouldAutoCreateFollowUpTask,
	shouldRetryBlockedIntegrationTask,
	shouldStopHiveLoop,
	syncTaskWithWorker,
	workerSnapshotToTaskState,
	withExistingOrchestratorQueueTransaction,
	writeOrchestratorArtifacts,
} from "./orchestrator.ts";

test("getOrchestratorPaths uses repo-local .hive/orchestrator files", () => {
	const paths = getOrchestratorPaths("/repo/project");
	assert.equal(paths.queueFile, "/repo/project/.hive/orchestrator/queue.json");
	assert.equal(paths.progressFile, "/repo/project/.hive/orchestrator/progress.md");
});

test("createOrchestratorQueue seeds defaults", () => {
	const queue = createOrchestratorQueue("/repo/project", {
		goal: "ship auth fixes",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	assert.equal(queue.goal, "ship auth fixes");
	assert.equal(queue.integrationBranch, "main");
	assert.equal(queue.finalCheckCommands[0], "just check");
	assert.equal(queue.tasks.length, 0);
});

test("limitDispatchTasks applies integer limits and rejects non-integers", () => {
	assert.deepEqual(limitDispatchTasks(["task-1", "task-2", "task-3"], 2), ["task-1", "task-2"]);
	assert.deepEqual(limitDispatchTasks(["task-1", "task-2"], undefined), ["task-1", "task-2"]);
	assert.throws(() => limitDispatchTasks(["task-1", "task-2"], 1.5), /dispatchLimit must be a positive integer/);
});

test("resolveHiveLoopIntervalSeconds uses strict explicit integer args before queue defaults", () => {
	assert.equal(resolveHiveLoopIntervalSeconds("", 45), 45);
	assert.equal(resolveHiveLoopIntervalSeconds(" 15 ", 45), 15);
	assert.equal(resolveHiveLoopIntervalSeconds("15s", 45), null);
	assert.equal(resolveHiveLoopIntervalSeconds("1.5", 45), null);
	assert.equal(resolveHiveLoopIntervalSeconds("", 0), DEFAULT_ORCHESTRATOR_POLL_INTERVAL_SECONDS);
	assert.equal(resolveHiveLoopIntervalSeconds("", 1.5), DEFAULT_ORCHESTRATOR_POLL_INTERVAL_SECONDS);
	assert.equal(resolveHiveLoopIntervalSeconds("", undefined), DEFAULT_ORCHESTRATOR_POLL_INTERVAL_SECONDS);
	assert.equal(resolveHiveLoopIntervalSeconds("abc", 45), null);
});


test("resolveHiveLoopInterval only loads persisted queue defaults when no explicit arg is supplied", async () => {
	let loads = 0;
	const explicit = await resolveHiveLoopInterval("15", async () => {
		loads += 1;
		return 45;
	});
	assert.equal(explicit, 15);
	assert.equal(loads, 0);

	const persisted = await resolveHiveLoopInterval("", async () => {
		loads += 1;
		return 45;
	});
	assert.equal(persisted, 45);
	assert.equal(loads, 1);

	const invalidPersisted = await resolveHiveLoopInterval("", async () => {
		loads += 1;
		return 0;
	});
	assert.equal(invalidPersisted, DEFAULT_ORCHESTRATOR_POLL_INTERVAL_SECONDS);
	assert.equal(loads, 2);
});

test("loadPersistedHiveLoopIntervalSeconds returns only valid persisted queue intervals", async () => {
	const repoRoot = await mkdtemp(path.join(os.tmpdir(), "hive-loop-interval-"));
	assert.equal(await loadPersistedHiveLoopIntervalSeconds(repoRoot), undefined);

	const paths = getOrchestratorPaths(repoRoot);
	const baseQueue = createOrchestratorQueue(repoRoot, {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});

	await writeOrchestratorArtifacts(paths, { ...baseQueue, pollIntervalSeconds: 45 });
	assert.equal(await loadPersistedHiveLoopIntervalSeconds(repoRoot), 45);

	await writeFile(paths.queueFile, `${JSON.stringify({ ...baseQueue, pollIntervalSeconds: 0 }, null, 2)}\n`, "utf8");
	assert.equal(await loadPersistedHiveLoopIntervalSeconds(repoRoot), undefined);

	await writeFile(paths.queueFile, `${JSON.stringify({ ...baseQueue, pollIntervalSeconds: 1.5 }, null, 2)}\n`, "utf8");
	assert.equal(await loadPersistedHiveLoopIntervalSeconds(repoRoot), undefined);
});

test("addTasksToQueue normalizes agents and allocates task ids", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue, added } = addTasksToQueue(
		base,
		[
			{ task: "fix login", agent: "1" },
			{ task: "add tests", agent: "agent-02", dependsOn: ["task-001"] },
		],
		"2026-04-06T00:01:00Z",
	);
	assert.deepEqual(
		added.map((task) => ({ id: task.id, agent: task.agent, dependsOn: task.dependsOn })),
		[
			{ id: "task-001", agent: "agent-01", dependsOn: [] },
			{ id: "task-002", agent: "agent-02", dependsOn: ["task-001"] },
		],
	);
	assert.equal(queue.updatedAt, "2026-04-06T00:01:00Z");
});

test("isTaskReadyForDispatch requires merged dependencies and only blocks on active worker execution", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(
		base,
		[
			{ task: "fix login", agent: "01" },
			{ task: "add tests", agent: "02", dependsOn: ["task-001"] },
			{ task: "follow-up on same agent", agent: "01" },
		],
		"2026-04-06T00:01:00Z",
	);
	assert.equal(isTaskReadyForDispatch(queue, queue.tasks[0]), true);
	assert.equal(isTaskReadyForDispatch(queue, queue.tasks[1]), false);
	assert.equal(isTaskReadyForDispatch(queue, queue.tasks[2]), true);

	const activeWorkerQueue = {
		...queue,
		tasks: [{ ...queue.tasks[0], state: "running" as const, workerRunning: true }, queue.tasks[1], queue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(activeWorkerQueue, activeWorkerQueue.tasks[2]), false);

	const legacyRunningQueue = {
		...queue,
		tasks: [{ ...queue.tasks[0], state: "running" as const, workerRunning: undefined }, queue.tasks[1], queue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(legacyRunningQueue, legacyRunningQueue.tasks[2]), false);

	const inactiveWorkerQueue = {
		...activeWorkerQueue,
		tasks: [{ ...activeWorkerQueue.tasks[0], workerRunning: false }, activeWorkerQueue.tasks[1], activeWorkerQueue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(inactiveWorkerQueue, inactiveWorkerQueue.tasks[2]), true);

	const doneQueue = {
		...queue,
		tasks: [{ ...queue.tasks[0], state: "done" as const }, queue.tasks[1], queue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(doneQueue, doneQueue.tasks[1]), false);
	assert.equal(isTaskReadyForDispatch(doneQueue, doneQueue.tasks[2]), true);

	const mergedQueue = {
		...doneQueue,
		tasks: [{ ...doneQueue.tasks[0], state: "merged" as const }, doneQueue.tasks[1], doneQueue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(mergedQueue, mergedQueue.tasks[1]), true);
	assert.equal(isTaskReadyForDispatch(mergedQueue, mergedQueue.tasks[2]), true);

	const blockedQueue = {
		...mergedQueue,
		tasks: [{ ...mergedQueue.tasks[0], state: "blocked" as const }, mergedQueue.tasks[1], mergedQueue.tasks[2]],
	};
	assert.equal(isTaskReadyForDispatch(blockedQueue, blockedQueue.tasks[2]), true);
});

function makeWorkerSnapshot(overrides: Partial<WorkerSnapshot>): WorkerSnapshot {
	return {
		repoRoot: "/repo/project",
		repoSlug: "project",
		agent: "agent-01",
		worktreeDir: "/tmp/worktree",
		isRunning: true,
		exitCode: null,
		pid: 123,
		status: { state: "implementing", summary: "Touch auth module", nextAction: "Run tests", headSha: "abc123" },
		launch: null,
		recentEvents: [],
		paths: {
			repoRoot: "/repo/project",
			repoSlug: "project",
			agent: "agent-01",
			worktreeDir: "/tmp/worktree",
			hiveDir: "/tmp/worktree/.hive",
			promptFile: "/tmp/worktree/.hive/worker-system-prompt.md",
			statusFile: "/tmp/worktree/.hive/status.json",
			launchFile: "/tmp/worktree/.hive/worker-launch.json",
			eventLogFile: "/tmp/worktree/.hive/worker-events.jsonl",
			stderrFile: "/tmp/worktree/.hive/worker-stderr.log",
			launcherStdoutFile: "/tmp/worktree/.hive/worker-launcher.out",
			launcherStderrFile: "/tmp/worktree/.hive/worker-launcher.err",
			reviewScriptFile: "/tmp/worktree/.hive/run-review.sh",
			reviewOutputFile: "/tmp/worktree/.hive/review-output.md",
			reviewDiffFile: "/tmp/worktree/.hive/review-diff.patch",
			pidFile: "/tmp/worktree/.hive/worker.pid",
			exitCodeFile: "/tmp/worktree/.hive/worker-exit-code",
			finishedAtFile: "/tmp/worktree/.hive/worker-finished-at",
		},
		...overrides,
	};
}

test("workerSnapshotToTaskState maps worker snapshots to queue states without synthesizing running work", () => {
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ status: { state: "blocked" } })), "blocked");
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ status: { state: "done" }, isRunning: false, exitCode: 0 })), "done");
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ isRunning: false, exitCode: 1, status: null })), "failed");
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ isRunning: false, exitCode: null, status: null, pid: null })), undefined);
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ isRunning: false, exitCode: null, status: { state: "booting" } })), undefined);
});

test("syncTaskWithWorker updates task metadata and captures worker head sha", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	const sync = syncTaskWithWorker(
		{ ...added[0], lastDispatchError: "previous launch failed" },
		makeWorkerSnapshot({ status: { state: "done", summary: "Ready to merge", headSha: "deadbeef" }, isRunning: false, exitCode: 0 }),
		"2026-04-06T00:02:00Z",
	);
	assert.equal(sync.task.state, "done");
	assert.equal(sync.task.workerSummary, "Ready to merge");
	assert.equal(sync.task.workerHeadSha, "deadbeef");
	assert.equal(sync.task.lastDispatchError, undefined);
	assert.match(sync.note || "", /planned -> done/);
});

test("syncTaskWithWorker updates poll metadata without a note when worker evidence is unchanged", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	const sync = syncTaskWithWorker(
		{
			...added[0],
			state: "running",
			launchedAt: "2026-04-06T00:01:00Z",
			lastPolledAt: "2026-04-06T00:02:00Z",
			workerHeadSha: "abc123",
		},
		makeWorkerSnapshot({ isRunning: true, exitCode: null, launchedAt: "2026-04-06T00:01:00Z", status: null }),
		"2026-04-06T00:03:00Z",
	);
	assert.equal(sync.note, undefined);
	assert.equal(sync.task.state, "running");
	assert.equal(sync.task.launchedAt, "2026-04-06T00:01:00Z");
	assert.equal(sync.task.lastPolledAt, "2026-04-06T00:03:00Z");
	assert.equal(sync.task.finishedAt, undefined);
	assert.equal(sync.task.workerRunning, true);
	assert.equal(sync.task.workerState, "running");
	assert.equal(sync.task.workerSummary, undefined);
	assert.equal(sync.task.workerNextAction, undefined);
	assert.equal(sync.task.workerExitCode, null);
	assert.equal(sync.task.workerHeadSha, "abc123");
	assert.equal(sync.task.workerStatusPath, "/tmp/worktree/.hive/status.json");
	assert.equal(sync.task.workerEventLogPath, "/tmp/worktree/.hive/worker-events.jsonl");
});

test("syncTaskWithWorker preserves prior task state when polling lacks positive evidence", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	const sync = syncTaskWithWorker(
		{
			...added[0],
			state: "running",
			workerRunning: true,
			workerState: "running",
			workerSummary: "Still working",
			workerNextAction: "Wait for test run",
			launchedAt: "2026-04-06T00:01:00Z",
			lastDispatchError: "previous launch failed",
		},
		makeWorkerSnapshot({ isRunning: false, exitCode: null, status: null, pid: null, launchedAt: undefined }),
		"2026-04-06T00:03:00Z",
	);
	assert.equal(sync.note, undefined);
	assert.equal(sync.task.state, "running");
	assert.equal(sync.task.workerRunning, false);
	assert.equal(sync.task.workerState, "running");
	assert.equal(sync.task.workerSummary, "Still working");
	assert.equal(sync.task.workerNextAction, "Wait for test run");
	assert.equal(sync.task.launchedAt, "2026-04-06T00:01:00Z");
	assert.equal(sync.task.finishedAt, undefined);
	assert.equal(sync.task.workerExitCode, null);
	assert.equal(sync.task.lastDispatchError, "previous launch failed");
});

test("applyTaskDispatchFailure keeps transient launch failures retryable", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	const failedDispatch = applyTaskDispatchFailure(
		{
			...queue.tasks[0],
			state: "running",
			launchedAt: "2026-04-06T00:01:30Z",
			finishedAt: "2026-04-06T00:01:45Z",
			workerRunning: true,
			workerState: "implementing",
			workerSummary: "Touch auth module",
			workerNextAction: "Run tests",
			workerExitCode: 17,
			workerHeadSha: "deadbeef",
			workerStatusPath: "/tmp/worktree/.hive/status.json",
			workerEventLogPath: "/tmp/worktree/.hive/worker-events.jsonl",
			integrationMessage: "stale integration message",
		},
		"control plane timeout",
		"2026-04-06T00:02:00Z",
	);
	assert.equal(failedDispatch.task.state, "planned");
	assert.equal(failedDispatch.task.dispatchAttempts, 1);
	assert.equal(failedDispatch.task.lastDispatchAttemptedAt, "2026-04-06T00:02:00Z");
	assert.equal(failedDispatch.task.lastDispatchError, "control plane timeout");
	assert.equal(failedDispatch.task.workerRunning, false);
	assert.equal(failedDispatch.task.launchedAt, undefined);
	assert.equal(failedDispatch.task.finishedAt, undefined);
	assert.equal(failedDispatch.task.workerState, undefined);
	assert.equal(failedDispatch.task.workerSummary, undefined);
	assert.equal(failedDispatch.task.workerNextAction, undefined);
	assert.equal(failedDispatch.task.workerExitCode, null);
	assert.equal(failedDispatch.task.workerHeadSha, undefined);
	assert.equal(failedDispatch.task.integrationMessage, undefined);
	assert.equal(isTaskReadyForDispatch({ ...queue, tasks: [failedDispatch.task] }, failedDispatch.task), true);
	assert.match(renderQueueSummary({ ...queue, tasks: [failedDispatch.task] }), /dispatch: control plane timeout/);
	assert.doesNotMatch(renderQueueSummary({ ...queue, tasks: [failedDispatch.task] }), /Touch auth module/);
});

test("applyTaskIntegrationResult records merged and blocked outcomes", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");

	const merged = applyTaskIntegrationResult(
		added[0],
		{ state: "merged", message: "cherry-picked and verified", mergedCommitSha: "cafebabe", workerHeadSha: "deadbeef" },
		"2026-04-06T00:02:00Z",
	);
	assert.equal(merged.task.state, "merged");
	assert.equal(merged.task.mergedCommitSha, "cafebabe");
	assert.equal(merged.task.integrationMessage, "cherry-picked and verified");
	assert.equal(merged.task.workerHeadSha, "deadbeef");

	const blocked = applyTaskIntegrationResult(
		added[0],
		{ state: "blocked", reason: "worker_dirty", message: "worker tree is dirty", workerHeadSha: "deadbeef" },
		"2026-04-06T00:02:00Z",
	);
	assert.equal(blocked.task.state, "blocked");
	assert.equal(blocked.task.integrationMessage, "worker tree is dirty");
	assert.equal(blocked.task.blockedReason, "worker_dirty");
	assert.equal(blocked.task.integrationAttempts, 1);
	assert.equal(blocked.task.workerHeadSha, "deadbeef");
});


test("retryable integration blocks can be retried on later ticks", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	assert.equal(
		shouldRetryBlockedIntegrationTask({
			...added[0],
			state: "blocked",
			workerState: "done",
			blockedReason: "coordinator_dirty",
		}),
		true,
	);
	assert.equal(
		shouldRetryBlockedIntegrationTask({
			...added[0],
			state: "blocked",
			workerState: "done",
			blockedReason: "integration_conflict",
		}),
		false,
	);
	assert.equal(
		shouldRetryBlockedIntegrationTask({
			...added[0],
			state: "blocked",
			workerState: "blocked",
			blockedReason: "coordinator_dirty",
		}),
		false,
	);
});

test("deriveDeterministicFixupCommands maps common check commands to deterministic fixups", () => {
	assert.deepEqual(deriveDeterministicFixupCommands("just check"), ["just fix"]);
	assert.deepEqual(deriveDeterministicFixupCommands("nix develop -c just check"), ["nix develop -c just fix"]);
	assert.deepEqual(deriveDeterministicFixupCommands("cargo fmt --check --all"), ["cargo fmt --all"]);
	assert.deepEqual(deriveDeterministicFixupCommands("git diff --check"), []);
});

test("shouldStopHiveLoop ignores retryable and replaced blocked tasks", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(
		base,
		[
			{ task: "fix login", agent: "01" },
			{ task: "follow-up", agent: "02", dependsOn: ["task-001"] },
		],
		"2026-04-06T00:01:00Z",
	);

	const retryable = {
		...queue,
		tasks: [
			{ ...queue.tasks[0], state: "blocked" as const, workerState: "done", blockedReason: "coordinator_dirty" },
			queue.tasks[1],
		],
	};
	assert.deepEqual(shouldStopHiveLoop(retryable), { stop: false });

	const replaced = {
		...queue,
		tasks: [
			{ ...queue.tasks[0], state: "blocked" as const, blockedReason: "integration_checks_failed", replacementTaskId: "task-003" },
			queue.tasks[1],
			{
				id: "task-003",
				title: "fix login (follow-up)",
				task: "follow-up",
				agent: "agent-01",
				state: "running" as const,
				verificationCommands: [],
				dependsOn: [],
				createdAt: "2026-04-06T00:02:00Z",
			},
		],
	};
	assert.deepEqual(shouldStopHiveLoop(replaced), { stop: false });

	const manualAttention = {
		...queue,
		tasks: [{ ...queue.tasks[0], state: "blocked" as const, blockedReason: "integration_conflict" }, queue.tasks[1]],
	};
	assert.deepEqual(shouldStopHiveLoop(manualAttention), {
		stop: true,
		reason: "queue has blocked or failed tasks requiring attention",
	});
});

test("checkWorkerCommitAlreadyIntegrated short-circuits when the worker commit is contained", async () => {
	const signal = new AbortController().signal;
	const calls: Array<{ args: string[]; options: { cwd?: string; signal?: AbortSignal; timeout?: number } | undefined }> = [];
	const pi = {
		exec: async (
			_command: string,
			args: string[],
			options?: { cwd?: string; signal?: AbortSignal; timeout?: number },
		) => {
			calls.push({ args, options });
			assert.match(args.join(" "), /merge-base --is-ancestor contained host/);
			return { code: 0, stdout: "", stderr: "" };
		},
	};

	const result = await checkWorkerCommitAlreadyIntegrated(pi as never, "/repo/project", "host", "contained", signal);
	assert.deepEqual(result, { state: "already_integrated" });
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].options, { cwd: "/repo/project", signal, timeout: 5000 });
});

test("checkWorkerCommitAlreadyIntegrated does not treat a tree-equal non-ancestor commit as already integrated", async () => {
	const signal = new AbortController().signal;
	const calls: Array<{ args: string[]; options: { cwd?: string; signal?: AbortSignal; timeout?: number } | undefined }> = [];
	const pi = {
		exec: async (
			_command: string,
			args: string[],
			options?: { cwd?: string; signal?: AbortSignal; timeout?: number },
		) => {
			calls.push({ args, options });
			if (args[2] === "merge-base") return { code: 1, stdout: "", stderr: "" };
			if (args[2] === "diff") return { code: 0, stdout: "", stderr: "" };
			assert.fail(`unexpected git command: ${args.join(" ")}`);
		},
	};

	const result = await checkWorkerCommitAlreadyIntegrated(pi as never, "/repo/project", "host", "tree-equal", signal);
	assert.deepEqual(result, { state: "needs_integration" });
	assert.deepEqual(
		calls.map((call) => ({ args: call.args.slice(2).join(" "), options: call.options })),
		[
			{ args: "merge-base --is-ancestor tree-equal host", options: { cwd: "/repo/project", signal, timeout: 5000 } },
			{ args: "diff --quiet host tree-equal", options: { cwd: "/repo/project", signal, timeout: 5000 } },
		],
	);
});

test("checkWorkerCommitAlreadyIntegrated reports containment-check failures", async () => {
	const pi = {
		exec: async () => ({ code: 128, stdout: "", stderr: "fatal: bad revision" }),
	};

	const result = await checkWorkerCommitAlreadyIntegrated(pi as never, "/repo/project", "host", "broken");
	assert.equal(result.state, "failed");
	if (result.state !== "failed") assert.fail("expected failure");
	assert.equal(result.reason, "diff_failed");
	assert.match(result.message, /failed to check whether host head host contains worker head broken/);
});

test("checkWorkerCommitAlreadyIntegrated reports diff failures after a non-contained commit", async () => {
	const pi = {
		exec: async (_command: string, args: string[]) => {
			if (args[2] === "merge-base") return { code: 1, stdout: "", stderr: "" };
			if (args[2] === "diff") return { code: 129, stdout: "", stderr: "fatal: diff failed" };
			assert.fail(`unexpected git command: ${args.join(" ")}`);
		},
	};

	const result = await checkWorkerCommitAlreadyIntegrated(pi as never, "/repo/project", "host", "needs-merge");
	assert.equal(result.state, "failed");
	if (result.state !== "failed") assert.fail("expected failure");
	assert.equal(result.reason, "diff_failed");
	assert.match(result.message, /failed to diff host against worker head needs-merge/);
});

test("follow-up tasks are auto-generated for recoverable integration failures", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(
		base,
		[
			{ task: "fix login", agent: "01" },
			{ task: "add docs", agent: "02", dependsOn: ["task-001"] },
		],
		"2026-04-06T00:01:00Z",
	);
	const blocked = applyTaskIntegrationResult(
		{ ...queue.tasks[0], state: "done" },
		{ state: "blocked", reason: "integration_conflict", message: "conflict in auth.ts", workerHeadSha: "deadbeef" },
		"2026-04-06T00:02:00Z",
	);
	assert.equal(shouldAutoCreateFollowUpTask({ state: "blocked", reason: "integration_conflict", message: "x" }), true);
	assert.equal(shouldAutoCreateFollowUpTask({ state: "blocked", reason: "worker_dirty", message: "x" }), false);

	const followUp = createAutoFollowUpTask({
		...queue,
		tasks: [blocked.task, queue.tasks[1]],
	}, blocked.task, { state: "blocked", reason: "integration_conflict", message: "conflict in auth.ts", workerHeadSha: "deadbeef" }, "2026-04-06T00:03:00Z");
	assert.equal(followUp.followUp.replacementForTaskId, blocked.task.id);
	assert.equal(followUp.followUp.autoGenerated, true);
	assert.equal(followUp.followUp.sourceHeadSha, "deadbeef");
	assert.equal(followUp.followUp.agent, blocked.task.agent);
	assert.deepEqual(followUp.queue.tasks.find((task) => task.id === "task-002")?.dependsOn, [followUp.followUp.id]);
	assert.equal(followUp.queue.tasks.find((task) => task.id === blocked.task.id)?.replacementTaskId, followUp.followUp.id);
});

test("createAutoFollowUpTask preserves unrelated dependencies while rewriting blocked edges", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(
		base,
		[
			{ task: "prep auth", agent: "01" },
			{ task: "fix login", agent: "02", dependsOn: ["task-001"] },
			{ task: "update docs", agent: "03", dependsOn: ["task-001", "task-002"] },
		],
		"2026-04-06T00:01:00Z",
	);
	const blockedTask = {
		...queue.tasks[1],
		state: "blocked" as const,
		dependsOn: ["task-001", "task-002"],
		integrationAttempts: 2,
		workerHeadSha: "deadbeef",
	};
	const followUp = createAutoFollowUpTask(
		{ ...queue, tasks: [queue.tasks[0], blockedTask, queue.tasks[2]] },
		blockedTask,
		{ state: "blocked", reason: "integration_conflict", message: "conflict in auth.ts", workerHeadSha: "deadbeef" },
		"2026-04-06T00:03:00Z",
	);
	assert.deepEqual(followUp.followUp.dependsOn, ["task-001"]);
	assert.match(followUp.followUp.title, /\(follow-up 3\)$/);
	assert.deepEqual(followUp.queue.tasks.find((task) => task.id === "task-003")?.dependsOn, ["task-001", followUp.followUp.id]);
	assert.deepEqual(followUp.queue.tasks.find((task) => task.id === "task-001")?.dependsOn, []);
	assert.equal(followUp.queue.tasks.find((task) => task.id === blockedTask.id)?.replacementTaskId, followUp.followUp.id);
});

test("renderOrchestratorPlan and summary include branch and integration details", () => {
	const base = createOrchestratorQueue("/repo/project", {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const { queue } = addTasksToQueue(base, [{ task: "fix login", agent: "01", verificationCommands: ["just check"] }], "2026-04-06T00:01:00Z");
	const mergedQueue = {
		...queue,
		tasks: [
			{
				...queue.tasks[0],
				state: "merged" as const,
				mergedCommitSha: "cafebabe12345678",
				integrationMessage: "verified in coordinator worktree",
			},
		],
	};
	const plan = renderOrchestratorPlan(mergedQueue);
	assert.match(plan, /Source branch/);
	assert.match(plan, /Coordinator integration worktree/);
	assert.match(plan, /main/);
	assert.match(plan, /verified in coordinator worktree/);

	const summary = renderQueueSummary(mergedQueue, ["merged task-001"]);
	assert.match(summary, /Source branch: main/);
	assert.match(summary, /Coordinator branch: main/);
	assert.match(summary, /Coordinator worktree:/);
	assert.match(summary, /merged cafebabe1234/);
	assert.match(summary, /merged task-001/);

	const widget = renderQueueWidget(mergedQueue);
	assert.match(widget[0], /Hive main/);
	assert.match(widget[1], /Goal:/);
});

test("writeOrchestratorArtifacts writes queue, plan, and progress files", async () => {
	const repoRoot = await mkdtemp(path.join(os.tmpdir(), "hive-orchestrator-"));
	const paths = getOrchestratorPaths(repoRoot);
	const queue = createOrchestratorQueue(repoRoot, {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	await writeOrchestratorArtifacts(paths, queue, [{ timestamp: "2026-04-06T00:00:00Z", text: "Initialized queue" }]);

	const loaded = await loadQueue(paths);
	assert.ok(loaded);
	assert.equal(loaded?.goal, "goal");
	assert.equal(loaded?.integrationBranch, "main");
	assert.match(await readFile(paths.planFile, "utf8"), /Hive orchestrator plan/);
	assert.match(await readFile(paths.progressFile, "utf8"), /Initialized queue/);
});

test("withExistingOrchestratorQueueTransaction reloads the freshest queue state for overlapping mutations", async () => {
	const repoRoot = await mkdtemp(path.join(os.tmpdir(), "hive-orchestrator-transaction-"));
	const paths = getOrchestratorPaths(repoRoot);
	const base = createOrchestratorQueue(repoRoot, {
		goal: "goal",
		integrationBranch: "main",
		now: "2026-04-06T00:00:00Z",
	});
	const seeded = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z").queue;
	await writeOrchestratorArtifacts(paths, seeded);

	let releaseFirstMutation!: () => void;
	const firstMutationReleased = new Promise<void>((resolve) => {
		releaseFirstMutation = resolve;
	});
	let firstMutationEntered!: () => void;
	const firstMutationHasEntered = new Promise<void>((resolve) => {
		firstMutationEntered = resolve;
	});
	const secondMutationObservedStates: string[] = [];
	let mutationQueue = Promise.resolve();
	const withTestMutationQueue = <T>(_filePath: string, mutate: () => Promise<T>) => {
		const run = mutationQueue.then(mutate, mutate);
		mutationQueue = run.then(() => undefined, () => undefined);
		return run;
	};

	const firstMutation = withExistingOrchestratorQueueTransaction(paths, withTestMutationQueue, async (queue) => {
		assert.ok(queue);
		firstMutationEntered();
		await firstMutationReleased;
		return {
			queue: {
				...queue,
				tasks: queue.tasks.map((task) =>
					task.id === "task-001"
						? { ...task, state: "running" as const, launchedAt: "2026-04-06T00:02:00Z" }
						: task,
				),
				updatedAt: "2026-04-06T00:02:00Z",
			},
			progressEntries: [{ timestamp: "2026-04-06T00:02:00Z", text: "Dispatched task-001 agent-01: fix login" }],
			result: undefined,
		};
	});

	await firstMutationHasEntered;
	const secondMutation = withExistingOrchestratorQueueTransaction(paths, withTestMutationQueue, async (queue) => {
		assert.ok(queue);
		secondMutationObservedStates.push(queue.tasks[0].state);
		const enqueued = addTasksToQueue(queue, [{ task: "add tests", agent: "02" }], "2026-04-06T00:03:00Z");
		return {
			queue: enqueued.queue,
			progressEntries: [{ timestamp: "2026-04-06T00:03:00Z", text: "Enqueued task-002 agent-02: add tests" }],
			result: undefined,
		};
	});

	releaseFirstMutation();
	await Promise.all([firstMutation, secondMutation]);

	const queue = await loadQueue(paths);
	assert.ok(queue);
	assert.deepEqual(secondMutationObservedStates, ["running"]);
	assert.deepEqual(
		queue?.tasks.map((task) => ({ id: task.id, state: task.state })),
		[
			{ id: "task-001", state: "running" },
			{ id: "task-002", state: "planned" },
		],
	);
	const progress = await readFile(paths.progressFile, "utf8");
	assert.match(progress, /Dispatched task-001 agent-01: fix login/);
	assert.match(progress, /Enqueued task-002 agent-02: add tests/);
});

test("withExistingOrchestratorQueueTransaction requires an initialized queue", async () => {
	const repoRoot = await mkdtemp(path.join(os.tmpdir(), "hive-orchestrator-missing-queue-"));
	const paths = getOrchestratorPaths(repoRoot);
	await assert.rejects(
		withExistingOrchestratorQueueTransaction(paths, async (_filePath, mutate) => await mutate(), async (queue) => ({
			queue,
			result: undefined,
		})),
		/Missing orchestrator queue: .*\.hive\/orchestrator\/queue\.json\. Run hive_orchestrator init first\./,
	);
});
