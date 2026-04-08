import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

export type WorkerPaths = {
	repoRoot: string;
	repoSlug: string;
	agent: string;
	worktreeDir: string;
	hiveDir: string;
	promptFile: string;
	statusFile: string;
	launchFile: string;
	eventLogFile: string;
	stderrFile: string;
	launcherStdoutFile: string;
	launcherStderrFile: string;
	pidFile: string;
	exitCodeFile: string;
	finishedAtFile: string;
};

export type CoordinatorPaths = {
	repoRoot: string;
	repoSlug: string;
	coordinatorKey: string;
	worktreeDir: string;
};

export type WorkerLaunchMetadata = {
	version: 1;
	repoRoot: string;
	repoSlug: string;
	agent: string;
	task: string;
	model?: string;
	tools?: string[];
	verificationCommands?: string[];
	additionalInstructions?: string;
	promptTemplatePath: string;
	promptFile: string;
	statusFile: string;
	eventLogFile: string;
	stderrFile: string;
	launchedAt: string;
};

export type WorkerSnapshot = {
	repoRoot: string;
	repoSlug: string;
	agent: string;
	worktreeDir: string;
	isRunning: boolean;
	exitCode: number | null;
	pid: number | null;
	task?: string;
	launchedAt?: string;
	status: Record<string, unknown> | null;
	statusParseError?: string;
	launch: WorkerLaunchMetadata | null;
	launchParseError?: string;
	recentEvents: string[];
	stderrTail?: string;
	paths: WorkerPaths;
};

export type WorkerCompletionValidation = {
	ok: boolean;
	errors: string[];
	headSha?: string;
};

export function stripAtPrefix(value: string): string {
	return value.startsWith("@") ? value.slice(1) : value;
}

export function normalizeAgentName(value: string): string {
	const trimmed = (value || "").trim();
	const match = /^agent-(\d+)$|^(\d+)$/.exec(trimmed);
	const digits = match?.[1] ?? match?.[2];
	if (!digits) {
		throw new Error(`Invalid agent id: ${value}. Use 01 or agent-01.`);
	}

	const parsed = Number.parseInt(digits, 10);
	if (!Number.isInteger(parsed) || parsed <= 0) {
		throw new Error(`Invalid agent id: ${value}. Agent number must be >= 1.`);
	}

	return `agent-${String(parsed).padStart(2, "0")}`;
}

export function agentOrdinal(agent: string): number {
	const normalized = normalizeAgentName(agent);
	return Number.parseInt(normalized.slice("agent-".length), 10);
}

export function getHiveStateDir(homeDir = os.homedir(), env = process.env): string {
	return env.HIVE_STATE || path.join(homeDir, ".local", "share", "agent-hive");
}

export function getRepoWorktreeKey(repoRoot: string): string {
	const normalizedRepoRoot = path.resolve(repoRoot);
	const repoSlug = path.basename(normalizedRepoRoot) || "repo";
	const repoRootHash = createHash("sha256").update(normalizedRepoRoot).digest("hex").slice(0, 16);
	return `${repoSlug}-${repoRootHash}`;
}

export function getWorkerPaths(
	repoRoot: string,
	agentInput: string,
	{
		homeDir = os.homedir(),
		hiveStateDir = getHiveStateDir(homeDir),
	}: { homeDir?: string; hiveStateDir?: string } = {},
): WorkerPaths {
	const normalizedRepoRoot = path.resolve(repoRoot);
	const repoSlug = path.basename(normalizedRepoRoot);
	const repoWorktreeKey = getRepoWorktreeKey(normalizedRepoRoot);
	const agent = normalizeAgentName(agentInput);
	const worktreeDir = path.join(hiveStateDir, "worktrees", repoWorktreeKey, agent);
	const hiveDir = path.join(worktreeDir, ".hive");

	return {
		repoRoot: normalizedRepoRoot,
		repoSlug,
		agent,
		worktreeDir,
		hiveDir,
		promptFile: path.join(hiveDir, "worker-system-prompt.md"),
		statusFile: path.join(hiveDir, "status.json"),
		launchFile: path.join(hiveDir, "worker-launch.json"),
		eventLogFile: path.join(hiveDir, "worker-events.jsonl"),
		stderrFile: path.join(hiveDir, "worker-stderr.log"),
		launcherStdoutFile: path.join(hiveDir, "worker-launcher.out"),
		launcherStderrFile: path.join(hiveDir, "worker-launcher.err"),
		pidFile: path.join(hiveDir, "worker.pid"),
		exitCodeFile: path.join(hiveDir, "worker-exit-code"),
		finishedAtFile: path.join(hiveDir, "worker-finished-at"),
	};
}

export function getCoordinatorPaths(
	repoRoot: string,
	coordinatorKey: string,
	{
		homeDir = os.homedir(),
		hiveStateDir = getHiveStateDir(homeDir),
	}: { homeDir?: string; hiveStateDir?: string } = {},
): CoordinatorPaths {
	const normalizedRepoRoot = path.resolve(repoRoot);
	const repoSlug = path.basename(normalizedRepoRoot);
	const repoWorktreeKey = getRepoWorktreeKey(normalizedRepoRoot);
	const worktreeDir = path.join(hiveStateDir, "coordinators", repoWorktreeKey, coordinatorKey);

	return {
		repoRoot: normalizedRepoRoot,
		repoSlug,
		coordinatorKey,
		worktreeDir,
	};
}

export function splitFrontmatter(raw: string): { frontmatter: Record<string, string>; body: string } {
	if (!raw.startsWith("---\n")) return { frontmatter: {}, body: raw };
	const end = raw.indexOf("\n---\n", 4);
	if (end === -1) return { frontmatter: {}, body: raw };

	const frontmatterText = raw.slice(4, end);
	const body = raw.slice(end + 5);
	const frontmatter: Record<string, string> = {};

	for (const line of frontmatterText.split("\n")) {
		const idx = line.indexOf(":");
		if (idx === -1) continue;
		const key = line.slice(0, idx).trim();
		const value = line.slice(idx + 1).trim();
		if (key) frontmatter[key] = value;
	}

	return { frontmatter, body };
}

export function renderPromptTemplate(template: string, args: string[]): string {
	const joined = args.join(" ");
	let output = template.replaceAll("$ARGUMENTS", joined).replaceAll("$@", joined);

	output = output.replace(/\$\{@:(\d+)(?::(\d+))?\}/g, (_match, startRaw: string, lengthRaw?: string) => {
		const start = Math.max(Number.parseInt(startRaw, 10) - 1, 0);
		const length = lengthRaw ? Math.max(Number.parseInt(lengthRaw, 10), 0) : undefined;
		const sliced = length === undefined ? args.slice(start) : args.slice(start, start + length);
		return sliced.join(" ");
	});

	output = output.replace(/\$(\d+)/g, (_match, indexRaw: string) => {
		const index = Number.parseInt(indexRaw, 10) - 1;
		return args[index] ?? "";
	});

	return output;
}

export function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function shellJoin(values: string[]): string {
	return values.map(shellQuote).join(" ");
}

export function buildWorkerSystemPrompt(
	templateText: string,
	task: string,
	{
		verificationCommands = [],
		additionalInstructions,
	}: {
		verificationCommands?: string[];
		additionalInstructions?: string;
	} = {},
): string {
	const { body } = splitFrontmatter(templateText);
	const rendered = renderPromptTemplate(body, [task]).trim();
	const sections = [rendered];

	sections.push(
		[
			"Runtime launcher context:",
			"- Keep machine-readable status in `.hive/status.json`.",
			"- The launcher captures the full pi JSON event stream in `.hive/worker-events.jsonl`.",
			"- The launcher captures stderr in `.hive/worker-stderr.log`.",
		].join("\n"),
	);

	if (verificationCommands.length > 0) {
		sections.push(["Focused verification commands:", ...verificationCommands.map((command) => `- ${command}`)].join("\n"));
	}

	if (additionalInstructions?.trim()) {
		sections.push(["Additional launcher instructions:", additionalInstructions.trim()].join("\n"));
	}

	return sections.filter(Boolean).join("\n\n");
}

export function createInitialWorkerStatus(
	task: string,
	verificationCommands: string[] = [],
	now = new Date().toISOString(),
): Record<string, unknown> {
	return {
		task,
		state: "booting",
		summary: "Booting worker run",
		assumptions: [],
		checks: verificationCommands,
		review: {
			status: "pending",
			scope: "worker delta",
			completedAt: null,
			summary: null,
		},
		finalVerification: {
			status: "pending",
			commands: verificationCommands,
			completedAt: null,
		},
		headSha: null,
		updatedAt: now,
		nextAction: "Start implementation",
	};
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPassedStatus(value: unknown): boolean {
	return value === "passed" || value === "done";
}

export function validateWorkerDoneStatus(status: Record<string, unknown> | null, actualHeadSha?: string): WorkerCompletionValidation {
	const errors: string[] = [];
	if (!isPlainObject(status)) {
		return { ok: false, errors: ["missing or invalid .hive/status.json object"] };
	}

	if (status.state !== "done") errors.push(`worker state must be done, got ${JSON.stringify(status.state)}`);
	if (typeof status.summary !== "string" || status.summary.trim() === "") errors.push("worker summary is required");
	if (typeof status.nextAction !== "string" || status.nextAction.trim() === "") errors.push("worker nextAction is required");
	if (typeof status.updatedAt !== "string" || status.updatedAt.trim() === "") errors.push("worker updatedAt is required");
	if (!Array.isArray(status.checks)) errors.push("worker checks must be an array");

	const headSha = typeof status.headSha === "string" && status.headSha.trim() !== "" ? status.headSha.trim() : undefined;
	if (!headSha) {
		errors.push("worker headSha is required");
	} else if (actualHeadSha && headSha !== actualHeadSha) {
		errors.push(`worker headSha ${headSha} does not match current HEAD ${actualHeadSha}`);
	}

	const review = status.review;
	if (!isPlainObject(review)) {
		errors.push("worker review object is required");
	} else {
		if (!isPassedStatus(review.status)) errors.push(`worker review.status must be passed or done, got ${JSON.stringify(review.status)}`);
		if (typeof review.scope !== "string" || review.scope.trim() === "") errors.push("worker review.scope is required");
		if (typeof review.completedAt !== "string" || review.completedAt.trim() === "") {
			errors.push("worker review.completedAt is required");
		}
		if (typeof review.summary !== "string" || review.summary.trim() === "") errors.push("worker review.summary is required");
	}

	const finalVerification = status.finalVerification;
	if (!isPlainObject(finalVerification)) {
		errors.push("worker finalVerification object is required");
	} else {
		if (!isPassedStatus(finalVerification.status)) {
			errors.push(
				`worker finalVerification.status must be passed or done, got ${JSON.stringify(finalVerification.status)}`,
			);
		}
		if (!Array.isArray(finalVerification.commands) || finalVerification.commands.some((command) => typeof command !== "string")) {
			errors.push("worker finalVerification.commands must be an array of strings");
		}
		if (typeof finalVerification.completedAt !== "string" || finalVerification.completedAt.trim() === "") {
			errors.push("worker finalVerification.completedAt is required");
		}
	}

	return {
		ok: errors.length === 0,
		errors,
		headSha,
	};
}

export function createWorkerLaunchMetadata(
	paths: WorkerPaths,
	{
		task,
		model,
		tools,
		verificationCommands,
		additionalInstructions,
		promptTemplatePath,
		launchedAt = new Date().toISOString(),
	}: {
		task: string;
		model?: string;
		tools?: string[];
		verificationCommands?: string[];
		additionalInstructions?: string;
		promptTemplatePath: string;
		launchedAt?: string;
	},
): WorkerLaunchMetadata {
	return {
		version: 1,
		repoRoot: paths.repoRoot,
		repoSlug: paths.repoSlug,
		agent: paths.agent,
		task,
		model,
		tools,
		verificationCommands,
		additionalInstructions,
		promptTemplatePath,
		promptFile: paths.promptFile,
		statusFile: paths.statusFile,
		eventLogFile: paths.eventLogFile,
		stderrFile: paths.stderrFile,
		launchedAt,
	};
}

export function buildWorkerRunScript({
	task,
	model,
	tools,
	promptPath = ".hive/worker-system-prompt.md",
	eventLogPath = ".hive/worker-events.jsonl",
	stderrPath = ".hive/worker-stderr.log",
	exitCodePath = ".hive/worker-exit-code",
	finishedAtPath = ".hive/worker-finished-at",
	runnerArgs = ["nix", "develop", "-c", "pi"],
}: {
	task: string;
	model?: string;
	tools?: string[];
	promptPath?: string;
	eventLogPath?: string;
	stderrPath?: string;
	exitCodePath?: string;
	finishedAtPath?: string;
	runnerArgs?: string[];
}): string {
	const commandArgs = [
		...runnerArgs,
		"--mode",
		"json",
		"-p",
		"--no-session",
		"--append-system-prompt",
		promptPath,
	];
	if (model) commandArgs.push("--model", model);
	if (tools && tools.length > 0) commandArgs.push("--tools", tools.join(","));
	commandArgs.push(`Task: ${task}`);

	const command = shellJoin(commandArgs);
	return [
		"set -uo pipefail",
		"mkdir -p .hive",
		`: > ${shellQuote(eventLogPath)}`,
		`: > ${shellQuote(stderrPath)}`,
		`: > ${shellQuote(exitCodePath)}`,
		`: > ${shellQuote(finishedAtPath)}`,
		`if ${command} > ${shellQuote(eventLogPath)} 2> ${shellQuote(stderrPath)}; then`,
		"\tstatus=0",
		"else",
		"\tstatus=$?",
		"fi",
		`printf '%s\n' \"$status\" > ${shellQuote(exitCodePath)}`,
		`date -u +%Y-%m-%dT%H:%M:%SZ > ${shellQuote(finishedAtPath)}`,
		"exit \"$status\"",
	].join("\n");
}

export function buildDetachedStartScript({
	runScript,
	pidPath = ".hive/worker.pid",
	launcherStdoutPath = ".hive/worker-launcher.out",
	launcherStderrPath = ".hive/worker-launcher.err",
}: {
	runScript: string;
	pidPath?: string;
	launcherStdoutPath?: string;
	launcherStderrPath?: string;
}): string {
	return [
		"set -euo pipefail",
		"mkdir -p .hive",
		`: > ${shellQuote(pidPath)}`,
		`nohup bash -lc ${shellQuote(runScript)} </dev/null > ${shellQuote(launcherStdoutPath)} 2> ${shellQuote(launcherStderrPath)} &`,
		`printf '%s\n' \"$!\" > ${shellQuote(pidPath)}`,
	].join("\n");
}

export async function writeWorkerLaunchFiles(
	paths: WorkerPaths,
	{
		prompt,
		launch,
		status,
	}: {
		prompt: string;
		launch: WorkerLaunchMetadata;
		status: Record<string, unknown>;
	},
): Promise<void> {
	await fs.mkdir(paths.hiveDir, { recursive: true });
	await Promise.all([
		fs.writeFile(paths.promptFile, `${prompt.trim()}\n`, "utf8"),
		fs.writeFile(paths.launchFile, `${JSON.stringify(launch, null, 2)}\n`, "utf8"),
		fs.writeFile(paths.statusFile, `${JSON.stringify(status, null, 2)}\n`, "utf8"),
		fs.writeFile(paths.eventLogFile, "", "utf8"),
		fs.writeFile(paths.stderrFile, "", "utf8"),
		fs.writeFile(paths.launcherStdoutFile, "", "utf8"),
		fs.writeFile(paths.launcherStderrFile, "", "utf8"),
		fs.writeFile(paths.pidFile, "", "utf8"),
		fs.writeFile(paths.exitCodeFile, "", "utf8"),
		fs.writeFile(paths.finishedAtFile, "", "utf8"),
	]);
}

function previewText(value: string, maxChars = 120): string {
	const normalized = value.replace(/\s+/g, " ").trim();
	if (normalized.length <= maxChars) return normalized;
	return `${normalized.slice(0, Math.max(0, maxChars - 3))}...`;
}

function extractAssistantPreview(message: any): string | null {
	if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return null;
	const text = message.content
		.filter((item: any) => item?.type === "text" && typeof item.text === "string")
		.map((item: any) => item.text)
		.join("\n")
		.trim();
	return text ? previewText(text) : null;
}

function summarizeToolArgs(toolName: string, args: Record<string, unknown> | undefined): string {
	if (!args) return toolName;
	if (toolName === "bash" && typeof args.command === "string") return `${toolName}: ${previewText(args.command, 80)}`;
	if (typeof args.path === "string") return `${toolName}: ${previewText(String(args.path), 80)}`;
	const json = previewText(JSON.stringify(args), 80);
	return `${toolName}: ${json}`;
}

export function summarizeJsonEventLog(raw: string, maxItems = 8): string[] {
	const summaries: string[] = [];
	for (const line of raw.split("\n")) {
		const trimmed = line.trim();
		if (!trimmed) continue;
		let event: any;
		try {
			event = JSON.parse(trimmed);
		} catch {
			continue;
		}

		switch (event.type) {
			case "tool_execution_start": {
				summaries.push(summarizeToolArgs(event.toolName || "tool", event.args));
				break;
			}
			case "message_end": {
				const assistantPreview = extractAssistantPreview(event.message);
				if (assistantPreview) summaries.push(`assistant: ${assistantPreview}`);
				break;
			}
			case "agent_end": {
				summaries.push("agent finished");
				break;
			}
		}
	}

	return summaries.slice(-maxItems);
}

export function tailText(raw: string, maxLines = 12, maxChars = 1500): string {
	const lines = raw
		.split("\n")
		.map((line) => line.trimEnd())
		.filter(Boolean);
	const joined = lines.slice(-maxLines).join("\n");
	if (joined.length <= maxChars) return joined;
	return joined.slice(joined.length - maxChars);
}

async function readTextIfExists(filePath: string): Promise<string | null> {
	try {
		return await fs.readFile(filePath, "utf8");
	} catch {
		return null;
	}
}

function parseJson<T>(raw: string | null): { value: T | null; error?: string } {
	if (raw == null || raw.trim() === "") return { value: null };
	try {
		return { value: JSON.parse(raw) as T };
	} catch (error) {
		return {
			value: null,
			error: error instanceof Error ? error.message : String(error),
		};
	}
}

function parseNumber(raw: string | null): number | null {
	if (raw == null) return null;
	const trimmed = raw.trim();
	if (!/^\d+$/.test(trimmed)) return null;
	const parsed = Number.parseInt(trimmed, 10);
	return Number.isInteger(parsed) ? parsed : null;
}

export async function loadWorkerSnapshot(paths: WorkerPaths, isRunning: boolean): Promise<WorkerSnapshot> {
	const [launchRaw, statusRaw, eventLogRaw, stderrRaw, exitCodeRaw, pidRaw] = await Promise.all([
		readTextIfExists(paths.launchFile),
		readTextIfExists(paths.statusFile),
		readTextIfExists(paths.eventLogFile),
		readTextIfExists(paths.stderrFile),
		readTextIfExists(paths.exitCodeFile),
		readTextIfExists(paths.pidFile),
	]);

	const launch = parseJson<WorkerLaunchMetadata>(launchRaw);
	const status = parseJson<Record<string, unknown>>(statusRaw);
	const task =
		(typeof status.value?.task === "string" ? status.value.task : undefined) ??
		(typeof launch.value?.task === "string" ? launch.value.task : undefined);
	const launchedAt = typeof launch.value?.launchedAt === "string" ? launch.value.launchedAt : undefined;

	return {
		repoRoot: paths.repoRoot,
		repoSlug: paths.repoSlug,
		agent: paths.agent,
		worktreeDir: paths.worktreeDir,
		isRunning,
		exitCode: parseNumber(exitCodeRaw),
		pid: parseNumber(pidRaw),
		task,
		launchedAt,
		status: status.value,
		statusParseError: status.error,
		launch: launch.value,
		launchParseError: launch.error,
		recentEvents: summarizeJsonEventLog(eventLogRaw ?? ""),
		stderrTail: stderrRaw ? tailText(stderrRaw) : undefined,
		paths,
	};
}
