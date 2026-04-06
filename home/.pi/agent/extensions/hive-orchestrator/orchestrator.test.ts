import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { WorkerSnapshot } from "./core.ts";
import {
	addTasksToQueue,
	createOrchestratorQueue,
	getOrchestratorPaths,
	isTaskReadyForDispatch,
	loadQueue,
	renderOrchestratorPlan,
	renderQueueSummary,
	syncTaskWithWorker,
	workerSnapshotToTaskState,
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
		now: "2026-04-06T00:00:00Z",
	});
	assert.equal(queue.goal, "ship auth fixes");
	assert.equal(queue.finalCheckCommands[0], "just check");
	assert.equal(queue.tasks.length, 0);
});

test("addTasksToQueue normalizes agents and allocates task ids", () => {
	const base = createOrchestratorQueue("/repo/project", { goal: "goal", now: "2026-04-06T00:00:00Z" });
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

test("isTaskReadyForDispatch respects dependencies and one-task-per-agent", () => {
	const base = createOrchestratorQueue("/repo/project", { goal: "goal", now: "2026-04-06T00:00:00Z" });
	const { queue } = addTasksToQueue(
		base,
		[
			{ task: "fix login", agent: "01" },
			{ task: "add tests", agent: "02", dependsOn: ["task-001"] },
			{ task: "follow-up", agent: "01" },
		],
		"2026-04-06T00:01:00Z",
	);
	assert.equal(isTaskReadyForDispatch(queue, queue.tasks[0]), true);
	assert.equal(isTaskReadyForDispatch(queue, queue.tasks[1]), false);

	const runningQueue = {
		...queue,
		tasks: [
			{ ...queue.tasks[0], state: "running" as const },
			queue.tasks[1],
			queue.tasks[2],
		],
	};
	assert.equal(isTaskReadyForDispatch(runningQueue, runningQueue.tasks[2]), false);

	const doneQueue = {
		...runningQueue,
		tasks: [
			{ ...runningQueue.tasks[0], state: "done" as const },
			runningQueue.tasks[1],
			runningQueue.tasks[2],
		],
	};
	assert.equal(isTaskReadyForDispatch(doneQueue, doneQueue.tasks[1]), true);
	assert.equal(isTaskReadyForDispatch(doneQueue, doneQueue.tasks[2]), true);
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
		status: { state: "implementing", summary: "Touch auth module", nextAction: "Run tests" },
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
			pidFile: "/tmp/worktree/.hive/worker.pid",
			exitCodeFile: "/tmp/worktree/.hive/worker-exit-code",
			finishedAtFile: "/tmp/worktree/.hive/worker-finished-at",
		},
		...overrides,
	};
}

test("workerSnapshotToTaskState maps worker snapshots to queue states", () => {
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ status: { state: "blocked" } })), "blocked");
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ status: { state: "done" }, isRunning: false, exitCode: 0 })), "done");
	assert.equal(workerSnapshotToTaskState(makeWorkerSnapshot({ isRunning: false, exitCode: 1, status: null })), "failed");
});

test("syncTaskWithWorker updates task metadata and emits state-change notes", () => {
	const base = createOrchestratorQueue("/repo/project", { goal: "goal", now: "2026-04-06T00:00:00Z" });
	const { added } = addTasksToQueue(base, [{ task: "fix login", agent: "01" }], "2026-04-06T00:01:00Z");
	const sync = syncTaskWithWorker(added[0], makeWorkerSnapshot({ status: { state: "done", summary: "Ready to merge" }, isRunning: false, exitCode: 0 }), "2026-04-06T00:02:00Z");
	assert.equal(sync.task.state, "done");
	assert.equal(sync.task.workerSummary, "Ready to merge");
	assert.match(sync.note || "", /planned -> done/);
});

test("renderOrchestratorPlan and summary include queued tasks", () => {
	const base = createOrchestratorQueue("/repo/project", { goal: "goal", now: "2026-04-06T00:00:00Z" });
	const { queue } = addTasksToQueue(base, [{ task: "fix login", agent: "01", verificationCommands: ["just check"] }], "2026-04-06T00:01:00Z");
	const plan = renderOrchestratorPlan(queue);
	assert.match(plan, /# Hive orchestrator plan/);
	assert.match(plan, /task-001/);
	assert.match(plan, /just check/);

	const summary = renderQueueSummary(queue, ["initialized queue"]);
	assert.match(summary, /planned=1/);
	assert.match(summary, /initialized queue/);
});

test("writeOrchestratorArtifacts writes queue, plan, and progress files", async () => {
	const repoRoot = await mkdtemp(path.join(os.tmpdir(), "hive-orchestrator-"));
	const paths = getOrchestratorPaths(repoRoot);
	const queue = createOrchestratorQueue(repoRoot, { goal: "goal", now: "2026-04-06T00:00:00Z" });
	await writeOrchestratorArtifacts(paths, queue, [{ timestamp: "2026-04-06T00:00:00Z", text: "Initialized queue" }]);

	const loaded = await loadQueue(paths);
	assert.ok(loaded);
	assert.equal(loaded?.goal, "goal");
	assert.match(await readFile(paths.planFile, "utf8"), /Hive orchestrator plan/);
	assert.match(await readFile(paths.progressFile, "utf8"), /Initialized queue/);
});
