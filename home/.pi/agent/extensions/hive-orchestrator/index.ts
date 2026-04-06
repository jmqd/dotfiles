import { existsSync } from "node:fs";
import { promises as fs } from "node:fs";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StringEnum } from "@mariozechner/pi-ai";
import { withFileMutationQueue, type ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Text } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";
import {
	agentOrdinal,
	buildDetachedStartScript,
	buildWorkerRunScript,
	buildWorkerSystemPrompt,
	createInitialWorkerStatus,
	createWorkerLaunchMetadata,
	getWorkerPaths,
	loadWorkerSnapshot,
	normalizeAgentName,
	stripAtPrefix,
	validateWorkerDoneStatus,
	writeWorkerLaunchFiles,
	type WorkerSnapshot,
} from "./core.ts";
import {
	addTasksToQueue,
	applyTaskIntegrationResult,
	createOrchestratorQueue,
	getOrchestratorPaths,
	isTaskReadyForDispatch,
	loadQueue,
	renderQueueSummary,
	syncTaskWithWorker,
	writeOrchestratorArtifacts,
	type OrchestratorProgressEntry,
	type OrchestratorQueue,
	type OrchestratorTask,
	type OrchestratorTaskInput,
	type TaskIntegrationResult,
} from "./orchestrator.ts";

const baseDir = dirname(fileURLToPath(import.meta.url));
const workerPromptTemplatePath = join(baseDir, "prompts", "hive-worker.md");
const orchestratorPromptTemplatePath = join(baseDir, "prompts", "hive-orchestrator.md");
const hiveSkillPath = join(baseDir, "skills", "hive-swarm", "SKILL.md");

type HiveWorkerDetails = {
	action: "launch" | "poll";
	worker: WorkerSnapshot;
	containerBootstrap?: string;
};

type HiveOrchestratorDetails = {
	action: "init" | "enqueue" | "poll" | "tick";
	queue: OrchestratorQueue;
	recentChanges: string[];
	polledTaskIds: string[];
	dispatchedTaskIds: string[];
	integratedTaskIds: string[];
};

const HiveWorkerParams = Type.Object({
	action: StringEnum(["launch", "poll"] as const, {
		description: "Whether to launch a worker or poll an existing worker.",
	}),
	repo: Type.Optional(
		Type.String({
			description: "Repository path. Defaults to the current git root. Use a path, not a hive repo slug.",
		}),
	),
	agent: Type.String({ description: "Worker id like 01 or agent-01." }),
	task: Type.Optional(Type.String({ description: "Worker task. Required for action=launch." })),
	model: Type.Optional(Type.String({ description: "Optional pi model override for the worker run." })),
	tools: Type.Optional(
		Type.Array(Type.String(), {
			description: "Optional explicit pi tool allowlist for the worker run.",
		}),
	),
	verificationCommands: Type.Optional(
		Type.Array(Type.String(), {
			description: "Focused verification commands to include in the worker prompt and initial status file.",
		}),
	),
	additionalInstructions: Type.Optional(
		Type.String({ description: "Extra launcher-provided instructions appended to the worker system prompt." }),
	),
});

const OrchestratorTaskItem = Type.Object({
	title: Type.Optional(Type.String({ description: "Short title for the subtask." })),
	task: Type.String({ description: "Full worker task prompt for this subtask." }),
	agent: Type.String({ description: "Worker id like 01 or agent-01." }),
	verificationCommands: Type.Optional(
		Type.Array(Type.String(), { description: "Focused verification commands for this task." }),
	),
	dependsOn: Type.Optional(Type.Array(Type.String(), { description: "Task ids that must finish merging before this one can launch." })),
	handoff: Type.Optional(Type.String({ description: "Short handoff contract for the worker." })),
});

const HiveOrchestratorParams = Type.Object({
	action: StringEnum(["init", "enqueue", "poll", "tick"] as const, {
		description: "Initialize the orchestrator, enqueue tasks, poll running workers, or tick the queue forward.",
	}),
	repo: Type.Optional(Type.String({ description: "Repository path. Defaults to the current git root." })),
	goal: Type.Optional(Type.String({ description: "Top-level orchestration goal. Required for action=init." })),
	finalCheckCommands: Type.Optional(
		Type.Array(Type.String(), {
			description: "Final repository-level verification commands. Defaults to ['just check'].",
		}),
	),
	pollIntervalSeconds: Type.Optional(
		Type.Number({
			description: "Recommended orchestrator poll interval in seconds. Defaults to 30.",
			minimum: 1,
		}),
	),
	overwrite: Type.Optional(Type.Boolean({ description: "Allow action=init to overwrite an existing queue." })),
	tasks: Type.Optional(Type.Array(OrchestratorTaskItem, { description: "Tasks to enqueue." })),
	dispatchLimit: Type.Optional(
		Type.Number({
			description: "Maximum number of ready tasks to dispatch during tick. Defaults to all ready tasks.",
			minimum: 1,
		}),
	),
});

function resolveHiveCommand(repoRoot: string): string {
	const candidate = join(repoRoot, "bin", "hive");
	return existsSync(candidate) ? candidate : "hive";
}

function formatWorkerState(worker: WorkerSnapshot): string {
	const statusState = typeof worker.status?.state === "string" ? worker.status.state : undefined;
	if (statusState) return statusState;
	if (worker.isRunning) return "running";
	if (worker.exitCode === 0) return "finished";
	if (worker.exitCode != null) return `failed (${worker.exitCode})`;
	return "idle";
}

function formatWorkerSummary(worker: WorkerSnapshot): string {
	const lines = [
		`${worker.agent} ${formatWorkerState(worker)}${worker.isRunning ? " [running]" : ""}`,
		`Repo: ${worker.repoRoot}`,
		`Worktree: ${worker.worktreeDir}`,
	];
	if (worker.task) lines.push(`Task: ${worker.task}`);
	if (typeof worker.status?.summary === "string") lines.push(`Summary: ${worker.status.summary}`);
	if (typeof worker.status?.nextAction === "string") lines.push(`Next: ${worker.status.nextAction}`);
	if (typeof worker.status?.headSha === "string") lines.push(`Worker head: ${worker.status.headSha}`);
	if (worker.exitCode != null) lines.push(`Exit code: ${worker.exitCode}`);
	if (worker.launchedAt) lines.push(`Launched: ${worker.launchedAt}`);
	if (worker.statusParseError) lines.push(`Status parse error: ${worker.statusParseError}`);
	if (worker.launchParseError) lines.push(`Launch parse error: ${worker.launchParseError}`);
	if (worker.recentEvents.length > 0) {
		lines.push("Recent events:");
		for (const event of worker.recentEvents) lines.push(`- ${event}`);
	}
	if (worker.stderrTail) {
		lines.push("stderr tail:");
		lines.push(worker.stderrTail);
	}
	lines.push(`Status file: ${worker.paths.statusFile}`);
	lines.push(`Event log: ${worker.paths.eventLogFile}`);
	return lines.join("\n");
}

async function execOrThrow(
	pi: ExtensionAPI,
	command: string,
	args: string[],
	cwd: string,
	signal?: AbortSignal,
	timeout?: number,
) {
	const result = await pi.exec(command, args, { cwd, signal, timeout });
	if (result.code !== 0) {
		throw new Error(`${command} ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
	return result;
}

async function execBashOrThrow(
	pi: ExtensionAPI,
	cwd: string,
	command: string,
	signal?: AbortSignal,
	timeout?: number,
) {
	const result = await pi.exec("bash", ["-lc", `set -euo pipefail\n${command}`], { cwd, signal, timeout });
	if (result.code !== 0) {
		throw new Error(`bash -lc ${JSON.stringify(command)} failed: ${result.stderr || result.stdout}`);
	}
	return result;
}

async function resolveRepoRoot(pi: ExtensionAPI, cwd: string, repoArg: string | undefined, signal?: AbortSignal) {
	const requestedPath = repoArg ? resolve(cwd, stripAtPrefix(repoArg)) : cwd;
	const result = await execOrThrow(pi, "git", ["-C", requestedPath, "rev-parse", "--show-toplevel"], cwd, signal, 5000);
	return result.stdout.trim();
}

async function getCurrentBranch(pi: ExtensionAPI, repoRoot: string, signal?: AbortSignal): Promise<string> {
	const result = await execOrThrow(pi, "git", ["-C", repoRoot, "branch", "--show-current"], repoRoot, signal, 5000);
	const branch = result.stdout.trim();
	if (!branch) throw new Error(`Repository is in detached HEAD state: ${repoRoot}`);
	return branch;
}

async function getHeadSha(pi: ExtensionAPI, cwd: string, signal?: AbortSignal): Promise<string> {
	const result = await execOrThrow(pi, "git", ["-C", cwd, "rev-parse", "HEAD"], cwd, signal, 5000);
	return result.stdout.trim();
}

async function ensureCleanWorkingTree(pi: ExtensionAPI, cwd: string, label: string, signal?: AbortSignal) {
	const result = await execOrThrow(pi, "git", ["-C", cwd, "status", "--porcelain"], cwd, signal, 5000);
	if (result.stdout.trim()) {
		throw new Error(`${label} has uncommitted changes:\n${result.stdout.trim()}`);
	}
}

async function isWorkerProcessRunning(
	pi: ExtensionAPI,
	hiveCommand: string,
	repoRoot: string,
	agent: string,
	signal?: AbortSignal,
): Promise<boolean> {
	const result = await pi.exec(
		hiveCommand,
		[
			"exec",
			"--repo",
			repoRoot,
			agent,
			"bash",
			"-lc",
			'pid="$(cat .hive/worker.pid 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid"',
		],
		{ cwd: repoRoot, signal, timeout: 5000 },
	);
	return result.code === 0;
}

async function readWorkerPromptTemplate() {
	return await fs.readFile(workerPromptTemplatePath, "utf8");
}

async function launchWorker(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: {
		repo?: string;
		agent: string;
		task: string;
		model?: string;
		tools?: string[];
		verificationCommands?: string[];
		additionalInstructions?: string;
	},
	signal?: AbortSignal,
	onUpdate?: (partial: { content: Array<{ type: "text"; text: string }>; details: HiveWorkerDetails }) => void,
): Promise<HiveWorkerDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const agent = normalizeAgentName(params.agent);
	const hiveCommand = resolveHiveCommand(repoRoot);
	const paths = getWorkerPaths(repoRoot, agent);

	const emitUpdate = (text: string, worker: WorkerSnapshot) => {
		onUpdate?.({
			content: [{ type: "text", text }],
			details: { action: "launch", worker },
		});
	};

	await execOrThrow(pi, hiveCommand, ["up", "--repo", repoRoot, "--agents", String(agentOrdinal(agent))], repoRoot, signal, 60_000);

	const wasRunning = await isWorkerProcessRunning(pi, hiveCommand, repoRoot, agent, signal);
	if (wasRunning) {
		throw new Error(`Worker ${agent} is already running. Poll it instead of launching a second run.`);
	}

	const promptTemplate = await readWorkerPromptTemplate();
	const prompt = buildWorkerSystemPrompt(promptTemplate, params.task, {
		verificationCommands: params.verificationCommands,
		additionalInstructions: params.additionalInstructions,
	});
	const launch = createWorkerLaunchMetadata(paths, {
		task: params.task,
		model: params.model,
		tools: params.tools,
		verificationCommands: params.verificationCommands,
		additionalInstructions: params.additionalInstructions,
		promptTemplatePath: workerPromptTemplatePath,
	});
	const status = createInitialWorkerStatus(params.task, params.verificationCommands, launch.launchedAt);

	await withFileMutationQueue(paths.statusFile, async () => {
		await writeWorkerLaunchFiles(paths, { prompt, launch, status });
	});

	const bootSnapshot = await loadWorkerSnapshot(paths, false);
	emitUpdate(`Prepared launch files for ${agent}`, bootSnapshot);

	const runScript = buildWorkerRunScript({
		task: params.task,
		model: params.model,
		tools: params.tools,
	});
	const startScript = buildDetachedStartScript({ runScript });
	const launchResult = await execOrThrow(
		pi,
		hiveCommand,
		["exec", "--repo", repoRoot, agent, "bash", "-lc", startScript],
		repoRoot,
		signal,
		15_000,
	);

	const running = await isWorkerProcessRunning(pi, hiveCommand, repoRoot, agent, signal);
	const snapshot = await loadWorkerSnapshot(paths, running);
	return {
		action: "launch",
		worker: snapshot,
		containerBootstrap: launchResult.stdout.trim() || undefined,
	};
}

async function pollWorker(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: { repo?: string; agent: string },
	signal?: AbortSignal,
): Promise<HiveWorkerDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const agent = normalizeAgentName(params.agent);
	const hiveCommand = resolveHiveCommand(repoRoot);
	const paths = getWorkerPaths(repoRoot, agent);
	const running = await isWorkerProcessRunning(pi, hiveCommand, repoRoot, agent, signal).catch(() => false);
	const snapshot = await loadWorkerSnapshot(paths, running);
	return { action: "poll", worker: snapshot };
}

function toProgressEntries(texts: string[], timestamp: string): OrchestratorProgressEntry[] {
	return texts.map((text) => ({ timestamp, text }));
}

async function loadQueueOrThrow(repoRoot: string) {
	const paths = getOrchestratorPaths(repoRoot);
	const queue = await loadQueue(paths);
	if (!queue) throw new Error(`Missing orchestrator queue: ${paths.queueFile}. Run hive_orchestrator init first.`);
	return { paths, queue };
}

async function refreshQueueFromWorkers(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	queue: OrchestratorQueue,
	repoRoot: string,
	signal?: AbortSignal,
): Promise<{ queue: OrchestratorQueue; recentChanges: string[]; polledTaskIds: string[] }> {
	const now = new Date().toISOString();
	const tasks = [...queue.tasks];
	const recentChanges: string[] = [];
	const polledTaskIds: string[] = [];

	for (let index = 0; index < tasks.length; index++) {
		const task = tasks[index];
		if (task.state !== "running") continue;
		const workerDetails = await pollWorker(pi, ctx, { repo: repoRoot, agent: task.agent }, signal);
		const synced = syncTaskWithWorker(task, workerDetails.worker, now);
		tasks[index] = synced.task;
		polledTaskIds.push(task.id);
		if (synced.note) recentChanges.push(synced.note);
	}

	return {
		queue: {
			...queue,
			tasks,
			updatedAt: now,
		},
		recentChanges,
		polledTaskIds,
	};
}

async function runFinalChecks(pi: ExtensionAPI, cwd: string, commands: string[], signal?: AbortSignal) {
	for (const command of commands) {
		await execBashOrThrow(pi, cwd, command, signal);
	}
}

async function tryAbortCherryPick(pi: ExtensionAPI, cwd: string, signal?: AbortSignal) {
	await pi.exec("git", ["-C", cwd, "cherry-pick", "--abort"], { cwd, signal, timeout: 5000 });
}

async function withTemporaryIntegrationWorktree<T>(
	pi: ExtensionAPI,
	repoRoot: string,
	taskId: string,
	signal: AbortSignal | undefined,
	fn: (worktreePath: string) => Promise<T>,
): Promise<T> {
	const worktreePath = join(os.tmpdir(), `pi-hive-integrate-${path.basename(repoRoot)}-${taskId}-${Date.now()}`);
	await execOrThrow(pi, "git", ["-C", repoRoot, "worktree", "add", "--detach", worktreePath, "HEAD"], repoRoot, signal, 30_000);
	try {
		return await fn(worktreePath);
	} finally {
		await pi.exec("git", ["-C", repoRoot, "worktree", "remove", "--force", worktreePath], {
			cwd: repoRoot,
			signal,
			timeout: 30_000,
		});
	}
}

async function integrateTask(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	queue: OrchestratorQueue,
	task: OrchestratorTask,
	signal?: AbortSignal,
): Promise<TaskIntegrationResult> {
	const repoRoot = queue.repoRoot;
	const currentBranch = await getCurrentBranch(pi, repoRoot, signal);
	if (currentBranch !== queue.integrationBranch) {
		return {
			state: "blocked",
			message: `current branch is ${currentBranch}, expected ${queue.integrationBranch}`,
			workerHeadSha: task.workerHeadSha,
		};
	}

	await ensureCleanWorkingTree(pi, repoRoot, `host repo ${repoRoot}`, signal);
	const workerDetails = await pollWorker(pi, ctx, { repo: repoRoot, agent: task.agent }, signal);
	const worker = workerDetails.worker;
	if (worker.isRunning) {
		return {
			state: "blocked",
			message: `worker ${task.agent} is still running`,
			workerHeadSha: task.workerHeadSha,
		};
	}

	await ensureCleanWorkingTree(pi, worker.worktreeDir, `worker worktree ${worker.worktreeDir}`, signal);
	const actualWorkerHeadSha = await getHeadSha(pi, worker.worktreeDir, signal);
	const validation = validateWorkerDoneStatus(worker.status, actualWorkerHeadSha);
	if (!validation.ok) {
		return {
			state: "blocked",
			message: `worker is not ready for integration: ${validation.errors.join("; ")}`,
			workerHeadSha: task.workerHeadSha,
		};
	}
	const workerHeadSha = validation.headSha ?? actualWorkerHeadSha;
	const hostHeadBefore = await getHeadSha(pi, repoRoot, signal);
	const diffCheck = await pi.exec("git", ["-C", repoRoot, "diff", "--quiet", hostHeadBefore, workerHeadSha], {
		cwd: repoRoot,
		signal,
		timeout: 5000,
	});
	if (diffCheck.code === 0) {
		return {
			state: "merged",
			message: `no-op: ${workerHeadSha.slice(0, 12)} already matches ${queue.integrationBranch}`,
			mergedCommitSha: hostHeadBefore,
			workerHeadSha,
		};
	}
	if (diffCheck.code !== 1) {
		return {
			state: "failed",
			message: `failed to diff host against worker head ${workerHeadSha}: ${diffCheck.stderr || diffCheck.stdout}`,
			workerHeadSha,
		};
	}

	try {
		await withTemporaryIntegrationWorktree(pi, repoRoot, task.id, signal, async (integrationWorktree) => {
			const cherryPick = await pi.exec(
				"git",
				["-C", integrationWorktree, "cherry-pick", "-x", workerHeadSha],
				{ cwd: integrationWorktree, signal, timeout: 60_000 },
			);
			if (cherryPick.code !== 0) {
				await tryAbortCherryPick(pi, integrationWorktree, signal);
				throw new Error(`temp cherry-pick failed: ${cherryPick.stderr || cherryPick.stdout}`);
			}

			await runFinalChecks(pi, integrationWorktree, queue.finalCheckCommands, signal);
		});
	} catch (error) {
		return {
			state: "blocked",
			message: error instanceof Error ? error.message : String(error),
			workerHeadSha,
		};
	}

	await ensureCleanWorkingTree(pi, repoRoot, `host repo ${repoRoot}`, signal);
	const hostHeadStill = await getHeadSha(pi, repoRoot, signal);
	if (hostHeadStill !== hostHeadBefore) {
		return {
			state: "blocked",
			message: `host branch moved during integration attempt (${hostHeadBefore.slice(0, 12)} -> ${hostHeadStill.slice(0, 12)})`,
			workerHeadSha,
		};
	}

	const hostCherryPick = await pi.exec("git", ["-C", repoRoot, "cherry-pick", "-x", workerHeadSha], {
		cwd: repoRoot,
		signal,
		timeout: 60_000,
	});
	if (hostCherryPick.code !== 0) {
		await tryAbortCherryPick(pi, repoRoot, signal);
		return {
			state: "blocked",
			message: `host cherry-pick failed: ${hostCherryPick.stderr || hostCherryPick.stdout}`,
			workerHeadSha,
		};
	}

	const mergedCommitSha = await getHeadSha(pi, repoRoot, signal);
	return {
		state: "merged",
		message: `cherry-picked ${workerHeadSha.slice(0, 12)} onto ${queue.integrationBranch} as ${mergedCommitSha.slice(0, 12)} after ${queue.finalCheckCommands.length} check(s)`,
		mergedCommitSha,
		workerHeadSha,
	};
}

async function initOrchestrator(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: {
		repo?: string;
		goal: string;
		finalCheckCommands?: string[];
		pollIntervalSeconds?: number;
		overwrite?: boolean;
	},
	signal?: AbortSignal,
): Promise<HiveOrchestratorDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const paths = getOrchestratorPaths(repoRoot);
	const existing = await loadQueue(paths);
	if (existing && !params.overwrite) {
		throw new Error(`Orchestrator queue already exists: ${paths.queueFile}. Use overwrite=true to replace it.`);
	}

	const integrationBranch = await getCurrentBranch(pi, repoRoot, signal);
	const now = new Date().toISOString();
	const queue = createOrchestratorQueue(repoRoot, {
		goal: params.goal,
		integrationBranch,
		pollIntervalSeconds: params.pollIntervalSeconds,
		finalCheckCommands: params.finalCheckCommands,
		now,
	});
	const recentChanges = [`Initialized orchestrator queue for goal: ${params.goal} on branch ${integrationBranch}`];
	await withFileMutationQueue(paths.queueFile, async () => {
		await writeOrchestratorArtifacts(paths, queue, toProgressEntries(recentChanges, now));
	});
	return { action: "init", queue, recentChanges, polledTaskIds: [], dispatchedTaskIds: [], integratedTaskIds: [] };
}

async function enqueueOrchestratorTasks(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: { repo?: string; tasks: OrchestratorTaskInput[] },
	signal?: AbortSignal,
): Promise<HiveOrchestratorDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const { paths, queue } = await loadQueueOrThrow(repoRoot);
	const now = new Date().toISOString();
	const result = addTasksToQueue(queue, params.tasks, now);
	const recentChanges = result.added.map((task) => `Enqueued ${task.id} ${task.agent}: ${task.title}`);
	await withFileMutationQueue(paths.queueFile, async () => {
		await writeOrchestratorArtifacts(paths, result.queue, toProgressEntries(recentChanges, now));
	});
	return {
		action: "enqueue",
		queue: result.queue,
		recentChanges,
		polledTaskIds: [],
		dispatchedTaskIds: [],
		integratedTaskIds: [],
	};
}

async function pollOrchestrator(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: { repo?: string },
	signal?: AbortSignal,
): Promise<HiveOrchestratorDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const { paths, queue } = await loadQueueOrThrow(repoRoot);
	const refreshed = await refreshQueueFromWorkers(pi, ctx, queue, repoRoot, signal);
	await withFileMutationQueue(paths.queueFile, async () => {
		await writeOrchestratorArtifacts(paths, refreshed.queue, toProgressEntries(refreshed.recentChanges, refreshed.queue.updatedAt));
	});
	return {
		action: "poll",
		queue: refreshed.queue,
		recentChanges: refreshed.recentChanges,
		polledTaskIds: refreshed.polledTaskIds,
		dispatchedTaskIds: [],
		integratedTaskIds: [],
	};
}

async function tickOrchestrator(
	pi: ExtensionAPI,
	ctx: { cwd: string },
	params: { repo?: string; dispatchLimit?: number },
	signal?: AbortSignal,
	onUpdate?: (partial: { content: Array<{ type: "text"; text: string }>; details: HiveOrchestratorDetails }) => void,
): Promise<HiveOrchestratorDetails> {
	const repoRoot = await resolveRepoRoot(pi, ctx.cwd, params.repo, signal);
	const { paths, queue } = await loadQueueOrThrow(repoRoot);
	const refreshed = await refreshQueueFromWorkers(pi, ctx, queue, repoRoot, signal);
	let nextQueue = refreshed.queue;
	const recentChanges = [...refreshed.recentChanges];
	const dispatchedTaskIds: string[] = [];
	const integratedTaskIds: string[] = [];

	const integrationCandidates = nextQueue.tasks.filter((task) => task.state === "done");
	for (const task of integrationCandidates) {
		const result = await integrateTask(pi, ctx, nextQueue, task, signal);
		const applied = applyTaskIntegrationResult(task, result, new Date().toISOString());
		nextQueue = {
			...nextQueue,
			tasks: nextQueue.tasks.map((item) => (item.id === task.id ? applied.task : item)),
			updatedAt: new Date().toISOString(),
		};
		recentChanges.push(applied.note);
		if (result.state === "merged") integratedTaskIds.push(task.id);
	}

	const readyTasks = nextQueue.tasks.filter((task) => isTaskReadyForDispatch(nextQueue, task));
	const limitedReadyTasks =
		typeof params.dispatchLimit === "number" ? readyTasks.slice(0, Math.max(0, Math.floor(params.dispatchLimit))) : readyTasks;

	for (const task of limitedReadyTasks) {
		const currentTask = nextQueue.tasks.find((item) => item.id === task.id);
		if (!currentTask || !isTaskReadyForDispatch(nextQueue, currentTask)) continue;
		try {
			const workerDetails = await launchWorker(
				pi,
				ctx,
				{
					repo: repoRoot,
					agent: currentTask.agent,
					task: currentTask.task,
					verificationCommands: currentTask.verificationCommands,
					additionalInstructions: currentTask.handoff,
				},
				signal,
				(partial) => {
					onUpdate?.({
						content: partial.content,
						details: {
							action: "tick",
							queue: nextQueue,
							recentChanges,
							polledTaskIds: refreshed.polledTaskIds,
							dispatchedTaskIds,
							integratedTaskIds,
						},
					});
				},
			);

			const taskIndex = nextQueue.tasks.findIndex((item) => item.id === currentTask.id);
			if (taskIndex !== -1) {
				const synced = syncTaskWithWorker(nextQueue.tasks[taskIndex], workerDetails.worker, new Date().toISOString());
				nextQueue = {
					...nextQueue,
					tasks: nextQueue.tasks.map((item, index) => (index === taskIndex ? synced.task : item)),
					updatedAt: new Date().toISOString(),
				};
			}
			dispatchedTaskIds.push(currentTask.id);
			recentChanges.push(`Dispatched ${currentTask.id} ${currentTask.agent}: ${currentTask.title}`);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			recentChanges.push(`Dispatch failed for ${currentTask.id}: ${message}`);
			nextQueue = {
				...nextQueue,
				tasks: nextQueue.tasks.map((item) =>
					item.id === currentTask.id
						? {
								...item,
								state: "failed",
								integrationMessage: `Launch failed: ${message}`,
								lastPolledAt: new Date().toISOString(),
							}
						: item,
				),
				updatedAt: new Date().toISOString(),
			};
		}
	}

	const progressTimestamp = nextQueue.updatedAt;
	await withFileMutationQueue(paths.queueFile, async () => {
		await writeOrchestratorArtifacts(paths, nextQueue, toProgressEntries(recentChanges, progressTimestamp));
	});

	return {
		action: "tick",
		queue: nextQueue,
		recentChanges,
		polledTaskIds: refreshed.polledTaskIds,
		dispatchedTaskIds,
		integratedTaskIds,
	};
}

export default function hiveOrchestrator(pi: ExtensionAPI) {
	pi.on("resources_discover", () => {
		return {
			promptPaths: [orchestratorPromptTemplatePath, workerPromptTemplatePath],
			skillPaths: [hiveSkillPath],
		};
	});

	pi.registerTool({
		name: "hive_worker",
		label: "Hive Worker",
		description:
			"Launch or poll a non-interactive hive worker in an isolated worktree. Launch writes .hive/status.json and captures pi JSON events for later polling.",
		promptSnippet: "Launch or poll a hive worker run and inspect its .hive/status.json plus JSON event log.",
		promptGuidelines: [
			"Use hive_worker with action='launch' to start exactly one clean subtask in one worker.",
			"Use hive_worker with action='poll' to inspect running state, .hive/status.json, recent event summaries, and exit code before deciding what to do next.",
		],
		parameters: HiveWorkerParams,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			if (params.action === "launch") {
				if (!params.task?.trim()) {
					throw new Error("action=launch requires task");
				}
				const details = await launchWorker(
					pi,
					ctx,
					{
						repo: params.repo,
						agent: params.agent,
						task: params.task,
						model: params.model,
						tools: params.tools,
						verificationCommands: params.verificationCommands,
						additionalInstructions: params.additionalInstructions,
					},
					signal,
					onUpdate as any,
				);
				return {
					content: [{ type: "text", text: formatWorkerSummary(details.worker) }],
					details,
				};
			}

			const details = await pollWorker(pi, ctx, {
				repo: params.repo,
				agent: params.agent,
			}, signal);
			return {
				content: [{ type: "text", text: formatWorkerSummary(details.worker) }],
				details,
			};
		},

		renderCall(args, theme) {
			let agent = "agent-??";
			if (args.agent) {
				try {
					agent = normalizeAgentName(String(args.agent));
				} catch {
					agent = String(args.agent);
				}
			}
			const repo = args.repo ? String(args.repo) : "<current-repo>";
			let text =
				theme.fg("toolTitle", theme.bold("hive_worker ")) +
				theme.fg("accent", String(args.action)) +
				theme.fg("muted", ` ${agent} in ${repo}`);
			if (args.action === "launch" && typeof args.task === "string") {
				const preview = args.task.length > 80 ? `${args.task.slice(0, 80)}...` : args.task;
				text += `\n  ${theme.fg("dim", preview)}`;
			}
			return new Text(text, 0, 0);
		},

		renderResult(result) {
			const text = result.content[0];
			const body = text?.type === "text" ? text.text : "(no output)";
			return new Text(body, 0, 0);
		},
	});

	pi.registerTool({
		name: "hive_orchestrator",
		label: "Hive Orchestrator",
		description:
			"Initialize and manage a repo-local hive orchestration queue under .hive/orchestrator, enqueue worker tasks, poll running workers, integrate done workers onto the host branch, run final checks in a temp worktree, and dispatch ready tasks.",
		promptSnippet: "Initialize, update, and tick the hive orchestrator queue for multi-worker coordination and integration.",
		promptGuidelines: [
			"Use hive_orchestrator with action='init' before dispatching a new swarm.",
			"Use action='enqueue' to record clean worker subtasks in .hive/orchestrator/queue.json before launching them.",
			"Use action='tick' as the default queue step: it polls running workers, integrates done workers after final checks, and dispatches dependency-ready planned tasks.",
		],
		parameters: HiveOrchestratorParams,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			let details: HiveOrchestratorDetails;
			switch (params.action) {
				case "init": {
					if (!params.goal?.trim()) throw new Error("action=init requires goal");
					details = await initOrchestrator(
						pi,
						ctx,
						{
							repo: params.repo,
							goal: params.goal,
							finalCheckCommands: params.finalCheckCommands,
							pollIntervalSeconds: params.pollIntervalSeconds,
							overwrite: params.overwrite,
						},
						signal,
					);
					break;
				}
				case "enqueue": {
					if (!params.tasks || params.tasks.length === 0) throw new Error("action=enqueue requires tasks");
					details = await enqueueOrchestratorTasks(pi, ctx, { repo: params.repo, tasks: params.tasks }, signal);
					break;
				}
				case "poll": {
					details = await pollOrchestrator(pi, ctx, { repo: params.repo }, signal);
					break;
				}
				case "tick": {
					details = await tickOrchestrator(pi, ctx, { repo: params.repo, dispatchLimit: params.dispatchLimit }, signal, onUpdate as any);
					break;
				}
			}

			return {
				content: [{ type: "text", text: renderQueueSummary(details.queue, details.recentChanges) }],
				details,
			};
		},

		renderCall(args, theme) {
			const repo = args.repo ? String(args.repo) : "<current-repo>";
			let text =
				theme.fg("toolTitle", theme.bold("hive_orchestrator ")) +
				theme.fg("accent", String(args.action)) +
				theme.fg("muted", ` in ${repo}`);
			if (args.action === "init" && typeof args.goal === "string") {
				text += `\n  ${theme.fg("dim", args.goal.length > 90 ? `${args.goal.slice(0, 90)}...` : args.goal)}`;
			}
			if (args.action === "enqueue" && Array.isArray(args.tasks)) {
				text += `\n  ${theme.fg("dim", `${args.tasks.length} task(s)`)}`;
			}
			return new Text(text, 0, 0);
		},

		renderResult(result) {
			const text = result.content[0];
			const body = text?.type === "text" ? text.text : "(no output)";
			return new Text(body, 0, 0);
		},
	});
}
