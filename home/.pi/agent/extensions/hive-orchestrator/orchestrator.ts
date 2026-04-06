import { promises as fs } from "node:fs";
import path from "node:path";
import { normalizeAgentName, type WorkerSnapshot } from "./core.ts";

export type OrchestratorPaths = {
	repoRoot: string;
	repoSlug: string;
	orchestratorDir: string;
	planFile: string;
	queueFile: string;
	progressFile: string;
};

export type OrchestratorTaskState = "planned" | "running" | "done" | "blocked" | "failed" | "merged";

export type OrchestratorTask = {
	id: string;
	title: string;
	task: string;
	agent: string;
	state: OrchestratorTaskState;
	verificationCommands: string[];
	dependsOn: string[];
	handoff?: string;
	createdAt: string;
	launchedAt?: string;
	finishedAt?: string;
	lastPolledAt?: string;
	workerState?: string;
	workerSummary?: string;
	workerNextAction?: string;
	workerExitCode?: number | null;
	workerStatusPath?: string;
	workerEventLogPath?: string;
};

export type OrchestratorQueue = {
	version: 1;
	goal: string;
	repoRoot: string;
	repoSlug: string;
	createdAt: string;
	updatedAt: string;
	pollIntervalSeconds: number;
	finalCheckCommands: string[];
	tasks: OrchestratorTask[];
};

export type OrchestratorTaskInput = {
	title?: string;
	task: string;
	agent: string;
	verificationCommands?: string[];
	dependsOn?: string[];
	handoff?: string;
};

export type OrchestratorProgressEntry = {
	timestamp: string;
	text: string;
};

export function getOrchestratorPaths(repoRoot: string): OrchestratorPaths {
	const normalizedRepoRoot = path.resolve(repoRoot);
	const repoSlug = path.basename(normalizedRepoRoot);
	const orchestratorDir = path.join(normalizedRepoRoot, ".hive", "orchestrator");
	return {
		repoRoot: normalizedRepoRoot,
		repoSlug,
		orchestratorDir,
		planFile: path.join(orchestratorDir, "plan.md"),
		queueFile: path.join(orchestratorDir, "queue.json"),
		progressFile: path.join(orchestratorDir, "progress.md"),
	};
}

export function createOrchestratorQueue(
	repoRoot: string,
	{
		goal,
		pollIntervalSeconds = 30,
		finalCheckCommands = ["just check"],
		now = new Date().toISOString(),
	}: {
		goal: string;
		pollIntervalSeconds?: number;
		finalCheckCommands?: string[];
		now?: string;
	},
): OrchestratorQueue {
	const normalizedRepoRoot = path.resolve(repoRoot);
	return {
		version: 1,
		goal,
		repoRoot: normalizedRepoRoot,
		repoSlug: path.basename(normalizedRepoRoot),
		createdAt: now,
		updatedAt: now,
		pollIntervalSeconds,
		finalCheckCommands,
		tasks: [],
	};
}

function nextTaskId(tasks: OrchestratorTask[]): string {
	const maxIndex = tasks.reduce((max, task) => {
		const match = /^task-(\d+)$/.exec(task.id);
		if (!match) return max;
		return Math.max(max, Number.parseInt(match[1], 10));
	}, 0);
	return `task-${String(maxIndex + 1).padStart(3, "0")}`;
}

function defaultTitle(task: string): string {
	const normalized = task.replace(/\s+/g, " ").trim();
	if (normalized.length <= 72) return normalized;
	return `${normalized.slice(0, 69)}...`;
}

export function addTasksToQueue(
	queue: OrchestratorQueue,
	tasks: OrchestratorTaskInput[],
	now = new Date().toISOString(),
): { queue: OrchestratorQueue; added: OrchestratorTask[] } {
	const existingTasks = [...queue.tasks];
	const added: OrchestratorTask[] = [];
	for (const input of tasks) {
		const task: OrchestratorTask = {
			id: nextTaskId(existingTasks),
			title: input.title?.trim() || defaultTitle(input.task),
			task: input.task,
			agent: normalizeAgentName(input.agent),
			state: "planned",
			verificationCommands: input.verificationCommands ?? [],
			dependsOn: input.dependsOn ?? [],
			handoff: input.handoff,
			createdAt: now,
		};
		existingTasks.push(task);
		added.push(task);
	}

	return {
		queue: {
			...queue,
			tasks: existingTasks,
			updatedAt: now,
		},
		added,
	};
}

export function isTaskReadyForDispatch(queue: OrchestratorQueue, task: OrchestratorTask): boolean {
	if (task.state !== "planned") return false;
	const dependencyMap = new Map(queue.tasks.map((item) => [item.id, item]));
	for (const dependencyId of task.dependsOn) {
		const dependency = dependencyMap.get(dependencyId);
		if (!dependency) return false;
		if (dependency.state !== "done" && dependency.state !== "merged") return false;
	}

	return !queue.tasks.some((item) => item.id !== task.id && item.agent === task.agent && item.state === "running");
}

export function summarizeQueueCounts(queue: OrchestratorQueue): Record<OrchestratorTaskState, number> {
	return queue.tasks.reduce<Record<OrchestratorTaskState, number>>(
		(acc, task) => {
			acc[task.state] += 1;
			return acc;
		},
		{ planned: 0, running: 0, done: 0, blocked: 0, failed: 0, merged: 0 },
	);
}

export function renderOrchestratorPlan(queue: OrchestratorQueue): string {
	const sections = [
		"# Hive orchestrator plan",
		"",
		"## Overall goal",
		"",
		queue.goal,
		"",
		"## Task breakdown",
		"",
	];

	if (queue.tasks.length === 0) {
		sections.push("- No tasks queued yet.");
	} else {
		for (const task of queue.tasks) {
			sections.push(`- ${task.id}: ${task.title}`);
			sections.push(`  - Agent: ${task.agent}`);
			sections.push(`  - State: ${task.state}`);
			sections.push(`  - Task: ${task.task}`);
			if (task.dependsOn.length > 0) sections.push(`  - Depends on: ${task.dependsOn.join(", ")}`);
			if (task.verificationCommands.length > 0) {
				sections.push(`  - Verification: ${task.verificationCommands.join("; ")}`);
			}
			if (task.handoff) sections.push(`  - Handoff: ${task.handoff}`);
		}
	}

	sections.push("", "## Dependency edges", "");
	const dependencyEdges = queue.tasks.flatMap((task) => task.dependsOn.map((dependencyId) => `- ${dependencyId} -> ${task.id}`));
	sections.push(...(dependencyEdges.length > 0 ? dependencyEdges : ["- None recorded."]));

	sections.push("", "## Worker assignment", "");
	sections.push(...(queue.tasks.length > 0 ? queue.tasks.map((task) => `- ${task.agent}: ${task.id} ${task.title}`) : ["- None assigned."]));

	sections.push("", "## Merge order", "");
	sections.push(...(queue.tasks.length > 0 ? queue.tasks.map((task) => `- ${task.id}`) : ["- No merge order yet."]));

	sections.push("", "## Final verification plan", "");
	sections.push(...queue.finalCheckCommands.map((command) => `- ${command}`));

	return `${sections.join("\n")}\n`;
}

export function renderQueueSummary(queue: OrchestratorQueue, recentChanges: string[] = []): string {
	const counts = summarizeQueueCounts(queue);
	const lines = [
		`Goal: ${queue.goal}`,
		`Repo: ${queue.repoRoot}`,
		`Tasks: ${queue.tasks.length} total | planned=${counts.planned} running=${counts.running} done=${counts.done} blocked=${counts.blocked} failed=${counts.failed} merged=${counts.merged}`,
		`Poll interval: ${queue.pollIntervalSeconds}s`,
		`Final checks: ${queue.finalCheckCommands.join(", ")}`,
	];

	if (queue.tasks.length > 0) {
		lines.push("Queue:");
		for (const task of queue.tasks) {
			const parts = [`- ${task.id}`, `[${task.state}]`, `${task.agent}`, task.title];
			if (task.workerSummary) parts.push(`— ${task.workerSummary}`);
			else if (task.workerNextAction) parts.push(`— next: ${task.workerNextAction}`);
			lines.push(parts.join(" "));
		}
	}

	if (recentChanges.length > 0) {
		lines.push("Recent changes:");
		for (const change of recentChanges) lines.push(`- ${change}`);
	}

	return lines.join("\n");
}

export function workerSnapshotToTaskState(worker: WorkerSnapshot): OrchestratorTaskState {
	const statusState = typeof worker.status?.state === "string" ? worker.status.state : undefined;
	if (statusState === "blocked") return "blocked";
	if (statusState === "done") return "done";
	if (worker.isRunning) return "running";
	if (worker.exitCode === 0) return "done";
	if (worker.exitCode != null) return "failed";
	return "running";
}

export function syncTaskWithWorker(
	task: OrchestratorTask,
	worker: WorkerSnapshot,
	now = new Date().toISOString(),
): { task: OrchestratorTask; note?: string } {
	const nextState = workerSnapshotToTaskState(worker);
	const workerSummary = typeof worker.status?.summary === "string" ? worker.status.summary : undefined;
	const workerNextAction = typeof worker.status?.nextAction === "string" ? worker.status.nextAction : undefined;
	const nextTask: OrchestratorTask = {
		...task,
		state: nextState,
		launchedAt: task.launchedAt ?? worker.launchedAt ?? now,
		finishedAt: nextState === "done" || nextState === "blocked" || nextState === "failed" ? now : task.finishedAt,
		lastPolledAt: now,
		workerState: typeof worker.status?.state === "string" ? worker.status.state : nextState,
		workerSummary,
		workerNextAction,
		workerExitCode: worker.exitCode,
		workerStatusPath: worker.paths.statusFile,
		workerEventLogPath: worker.paths.eventLogFile,
	};

	const stateChanged = task.state !== nextState;
	const summaryChanged = workerSummary && workerSummary !== task.workerSummary;
	if (!stateChanged && !summaryChanged) return { task: nextTask };

	if (stateChanged) {
		return {
			task: nextTask,
			note: `${task.id} ${task.title}: ${task.state} -> ${nextState}${workerSummary ? ` (${workerSummary})` : ""}`,
		};
	}

	return {
		task: nextTask,
		note: `${task.id} ${task.title}: ${workerSummary}`,
	};
}

export async function loadQueue(paths: OrchestratorPaths): Promise<OrchestratorQueue | null> {
	try {
		const raw = await fs.readFile(paths.queueFile, "utf8");
		return JSON.parse(raw) as OrchestratorQueue;
	} catch {
		return null;
	}
}

function formatProgressEntries(entries: OrchestratorProgressEntry[]): string {
	return entries.map((entry) => `- ${entry.timestamp} ${entry.text}`).join("\n");
}

export async function writeOrchestratorArtifacts(
	paths: OrchestratorPaths,
	queue: OrchestratorQueue,
	progressEntries: OrchestratorProgressEntry[] = [],
): Promise<void> {
	await fs.mkdir(paths.orchestratorDir, { recursive: true });
	await Promise.all([
		fs.writeFile(paths.queueFile, `${JSON.stringify(queue, null, 2)}\n`, "utf8"),
		fs.writeFile(paths.planFile, renderOrchestratorPlan(queue), "utf8"),
	]);

	if (progressEntries.length > 0) {
		let prefix = "";
		try {
			await fs.access(paths.progressFile);
			prefix = "\n";
		} catch {
			prefix = "# Hive orchestrator progress\n\n";
		}
		await fs.appendFile(paths.progressFile, `${prefix}${formatProgressEntries(progressEntries)}\n`, "utf8");
	}
}
