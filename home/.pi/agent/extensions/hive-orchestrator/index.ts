import { existsSync } from "node:fs";
import { promises as fs } from "node:fs";
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
	writeWorkerLaunchFiles,
	type WorkerSnapshot,
} from "./core.ts";

const baseDir = dirname(fileURLToPath(import.meta.url));
const workerPromptTemplatePath = join(baseDir, "prompts", "hive-worker.md");
const orchestratorPromptTemplatePath = join(baseDir, "prompts", "hive-orchestrator.md");
const hiveSkillPath = join(baseDir, "skills", "hive-swarm", "SKILL.md");

type HiveWorkerDetails = {
	action: "launch" | "poll";
	worker: WorkerSnapshot;
	containerBootstrap?: string;
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

async function resolveRepoRoot(pi: ExtensionAPI, cwd: string, repoArg: string | undefined, signal?: AbortSignal) {
	const requestedPath = repoArg ? resolve(cwd, stripAtPrefix(repoArg)) : cwd;
	const result = await execOrThrow(pi, "git", ["-C", requestedPath, "rev-parse", "--show-toplevel"], cwd, signal, 5000);
	return result.stdout.trim();
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
				const details = await launchWorker(pi, ctx, {
					repo: params.repo,
					agent: params.agent,
					task: params.task,
					model: params.model,
					tools: params.tools,
					verificationCommands: params.verificationCommands,
					additionalInstructions: params.additionalInstructions,
				}, signal, onUpdate as any);
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

		renderResult(result, _options, _theme) {
			const details = result.details as HiveWorkerDetails | undefined;
			const text = result.content[0];
			const body = text?.type === "text" ? text.text : "(no output)";
			if (!details) return new Text(body, 0, 0);
			return new Text(body, 0, 0);
		},
	});
}
