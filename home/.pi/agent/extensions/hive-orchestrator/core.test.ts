import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
	agentOrdinal,
	buildDetachedStartScript,
	buildWorkerRunScript,
	buildWorkerSystemPrompt,
	createInitialWorkerStatus,
	getHiveStateDir,
	getRepoWorktreeKey,
	validateWorkerDoneStatus,
	getWorkerPaths,
	loadWorkerSnapshot,
	normalizeAgentName,
	renderPromptTemplate,
	splitFrontmatter,
	summarizeJsonEventLog,
	tailText,
} from "./core.ts";

test("normalizeAgentName accepts short and full agent ids", () => {
	assert.equal(normalizeAgentName("01"), "agent-01");
	assert.equal(normalizeAgentName("1"), "agent-01");
	assert.equal(normalizeAgentName("agent-7"), "agent-07");
	assert.equal(agentOrdinal("agent-12"), 12);
	assert.equal(agentOrdinal("12"), 12);
	assert.throws(() => normalizeAgentName("agent-x"), /Invalid agent id/);
});

test("getHiveStateDir prefers env override", () => {
	assert.equal(getHiveStateDir("/home/test", { HIVE_STATE: "/tmp/hive" } as NodeJS.ProcessEnv), "/tmp/hive");
	assert.equal(getHiveStateDir("/home/test", {} as NodeJS.ProcessEnv), "/home/test/.local/share/agent-hive");
});

test("getWorkerPaths keys hive worktrees by stable repo-root-specific path", () => {
	const repoWorktreeKey = getRepoWorktreeKey("/repo/project");
	const paths = getWorkerPaths("/repo/project", "02", { hiveStateDir: "/state/hive" });
	assert.equal(paths.repoSlug, "project");
	assert.equal(paths.agent, "agent-02");
	assert.equal(repoWorktreeKey, getRepoWorktreeKey("/repo/./project"));
	assert.match(repoWorktreeKey, /^project-[0-9a-f]{16}$/);
	assert.equal(paths.worktreeDir, `/state/hive/worktrees/${repoWorktreeKey}/agent-02`);
	assert.equal(paths.statusFile, `/state/hive/worktrees/${repoWorktreeKey}/agent-02/.hive/status.json`);
});

test("getWorkerPaths avoids collisions for repos with the same basename", () => {
	const first = getWorkerPaths("/repo-a/project", "01", { hiveStateDir: "/state/hive" });
	const second = getWorkerPaths("/repo-b/project", "01", { hiveStateDir: "/state/hive" });
	assert.equal(first.repoSlug, "project");
	assert.equal(second.repoSlug, "project");
	assert.notEqual(getRepoWorktreeKey("/repo-a/project"), getRepoWorktreeKey("/repo-b/project"));
	assert.notEqual(first.worktreeDir, second.worktreeDir);
});

test("splitFrontmatter and renderPromptTemplate support prompt-template style args", () => {
	assert.deepEqual(splitFrontmatter("---\ndescription: test\n---\nbody\n"), {
		frontmatter: { description: "test" },
		body: "body\n",
	});

	const rendered = renderPromptTemplate("Task: $1\nAll: $@\nTail: ${@:2}", ["alpha", "beta", "gamma"]);
	assert.equal(rendered, "Task: alpha\nAll: alpha beta gamma\nTail: beta gamma");
});

test("renderPromptTemplate clamps empty and out-of-range prompt expressions", () => {
	const rendered = renderPromptTemplate(
		"Zero start: ${@:0:2}\nZero length: ${@:2:0}\nMissing arg: $4\nPast end: ${@:5}",
		["alpha", "beta", "gamma"],
	);
	assert.equal(rendered, "Zero start: alpha beta\nZero length: \nMissing arg: \nPast end: ");
});

test("renderPromptTemplate leaves unsupported slice syntax untouched and supports multi-digit args", () => {
	const rendered = renderPromptTemplate("Tenth: $10\nInvalid: ${@:x}", [
		"one",
		"two",
		"three",
		"four",
		"five",
		"six",
		"seven",
		"eight",
		"nine",
		"ten",
	]);
	assert.equal(rendered, "Tenth: ten\nInvalid: ${@:x}");
});

test("buildWorkerSystemPrompt strips frontmatter and appends launcher context", () => {
	const prompt = buildWorkerSystemPrompt(
		"---\ndescription: worker\n---\nAssigned subtask: $@\n",
		"fix login",
		{
			verificationCommands: ["just check", "node --test"],
			additionalInstructions: "Prefer the smallest coherent patch.",
		},
	);

	assert.match(prompt, /Assigned subtask: fix login/);
	assert.match(prompt, /\.hive\/status\.json/);
	assert.match(prompt, /\.hive\/worker-events\.jsonl/);
	assert.match(prompt, /just check/);
	assert.match(prompt, /Prefer the smallest coherent patch/);
});

test("buildWorkerRunScript launches pi in json mode with captured logs", () => {
	const script = buildWorkerRunScript({
		task: "implement retry handling",
		model: "anthropic/claude-sonnet-4-5",
		tools: ["read", "bash", "edit", "write"],
	});

	assert.match(script, /nix' 'develop' '-c' 'pi'/);
	assert.match(script, /'--mode' 'json' '-p' '--no-session'/);
	assert.match(script, /'--append-system-prompt' '.hive\/worker-system-prompt\.md'/);
	assert.match(script, /'--model' 'anthropic\/claude-sonnet-4-5'/);
	assert.match(script, /'--tools' 'read,bash,edit,write'/);
	assert.match(script, /\.hive\/worker-events\.jsonl/);
	assert.match(script, /\.hive\/worker-stderr\.log/);
	assert.match(script, /worker-exit-code/);
});

test("buildDetachedStartScript backgrounds the worker and records its pid", () => {
	const script = buildDetachedStartScript({ runScript: "echo hi" });
	assert.match(script, /nohup bash -lc/);
	assert.match(script, /worker-launcher\.out/);
	assert.match(script, /worker-launcher\.err/);
	assert.match(script, /worker\.pid/);
});

test("createInitialWorkerStatus starts in booting state", () => {
	assert.deepEqual(createInitialWorkerStatus("fix auth", ["just check"], "2026-04-06T00:00:00.000Z"), {
		task: "fix auth",
		state: "booting",
		summary: "Booting worker run",
		assumptions: [],
		checks: ["just check"],
		review: {
			status: "pending",
			scope: "worker delta",
			completedAt: null,
			summary: null,
		},
		finalVerification: {
			status: "pending",
			commands: ["just check"],
			completedAt: null,
		},
		headSha: null,
		updatedAt: "2026-04-06T00:00:00.000Z",
		nextAction: "Start implementation",
	});
});


test("validateWorkerDoneStatus enforces committed reviewed done-state", () => {
	const valid = validateWorkerDoneStatus(
		{
			state: "done",
			summary: "Ready to merge",
			nextAction: "Wait for orchestrator merge",
			updatedAt: "2026-04-06T00:00:00Z",
			checks: ["just check"],
			headSha: "deadbeef",
			review: {
				status: "passed",
				scope: "worker delta",
				completedAt: "2026-04-06T00:00:00Z",
				summary: "Addressed correctness and testing feedback",
			},
			finalVerification: {
				status: "passed",
				commands: ["just check"],
				completedAt: "2026-04-06T00:00:00Z",
			},
		},
		"deadbeef",
	);
	assert.deepEqual(valid, { ok: true, errors: [], headSha: "deadbeef" });

	const invalid = validateWorkerDoneStatus(
		{
			state: "done",
			summary: "Ready to merge",
			nextAction: "Wait",
			updatedAt: "2026-04-06T00:00:00Z",
			checks: ["just check"],
			headSha: "deadbeef",
			review: { status: "pending", scope: "worker delta" },
			finalVerification: { status: "pending", commands: [] },
		},
		"cafebabe",
	);
	assert.equal(invalid.ok, false);
	assert.match(invalid.errors.join("\n"), /headSha .* does not match current HEAD/);
	assert.match(invalid.errors.join("\n"), /review\.status must be passed or done/);
	assert.match(invalid.errors.join("\n"), /review\.completedAt is required/);
	assert.match(invalid.errors.join("\n"), /review\.summary is required/);
	assert.match(invalid.errors.join("\n"), /finalVerification\.status must be passed or done/);
	assert.match(invalid.errors.join("\n"), /finalVerification\.completedAt is required/);
	});

test("summarizeJsonEventLog extracts assistant and tool updates", () => {
	const raw = [
		JSON.stringify({ type: "session", id: "1" }),
		JSON.stringify({ type: "tool_execution_start", toolName: "bash", args: { command: "git status --short" } }),
		JSON.stringify({
			type: "message_end",
			message: {
				role: "assistant",
				content: [{ type: "text", text: "Implemented retry handling.\nUpdated tests." }],
			},
		}),
		JSON.stringify({ type: "agent_end" }),
	].join("\n");

	assert.deepEqual(summarizeJsonEventLog(raw), [
		"bash: git status --short",
		"assistant: Implemented retry handling. Updated tests.",
		"agent finished",
	]);
});

test("tailText returns the end of long stderr output", () => {
	const tailed = tailText(["a", "b", "c", "d"].join("\n"), 2, 100);
	assert.equal(tailed, "c\nd");
});

async function setupTempWorkerPaths(agent = "01") {
	const tempDir = await mkdtemp(path.join(os.tmpdir(), "hive-worker-core-"));
	const paths = getWorkerPaths("/repo/project", agent, { hiveStateDir: tempDir });
	await mkdir(path.dirname(paths.launchFile), { recursive: true });
	return paths;
}

async function writeWorkerFiles(
	paths: ReturnType<typeof getWorkerPaths>,
	{
		launchFileText,
		statusFileText,
		eventLogFileText,
		stderrFileText,
		exitCodeText,
		pidText,
	}: {
		launchFileText?: string;
		statusFileText?: string;
		eventLogFileText?: string;
		stderrFileText?: string;
		exitCodeText?: string;
		pidText?: string;
	},
) {
	if (launchFileText !== undefined) await writeFile(paths.launchFile, launchFileText, "utf8");
	if (statusFileText !== undefined) await writeFile(paths.statusFile, statusFileText, "utf8");
	if (eventLogFileText !== undefined) await writeFile(paths.eventLogFile, eventLogFileText, "utf8");
	if (stderrFileText !== undefined) await writeFile(paths.stderrFile, stderrFileText, "utf8");
	if (exitCodeText !== undefined) await writeFile(paths.exitCodeFile, exitCodeText, "utf8");
	if (pidText !== undefined) await writeFile(paths.pidFile, pidText, "utf8");
}

test("loadWorkerSnapshot surfaces malformed status JSON and ignores nonnumeric pid/exit files", async () => {
	const paths = await setupTempWorkerPaths();
	await writeWorkerFiles(paths, {
		launchFileText: JSON.stringify({ task: "fix auth", launchedAt: "2026-04-06T00:00:00Z" }),
		statusFileText: "{\"task\":",
		exitCodeText: "not-a-number\n",
		pidText: "12x\n",
	});

	const assumeRunning = true;
	const snapshot = await loadWorkerSnapshot(paths, assumeRunning);
	assert.equal(snapshot.isRunning, true);
	assert.equal(snapshot.task, "fix auth");
	assert.equal(snapshot.status, null);
	assert.equal(snapshot.exitCode, null);
	assert.equal(snapshot.pid, null);
	assert.equal(snapshot.launch?.task, "fix auth");
	assert.equal(typeof snapshot.statusParseError, "string");
	assert.equal(snapshot.launchParseError, undefined);
});

test("loadWorkerSnapshot surfaces malformed launch JSON and keeps status-derived task data", async () => {
	const paths = await setupTempWorkerPaths();
	await writeWorkerFiles(paths, {
		launchFileText: "{bad json",
		statusFileText: JSON.stringify({ task: "fix docs", state: "booting", summary: "Starting" }),
	});

	const assumeRunning = false;
	const snapshot = await loadWorkerSnapshot(paths, assumeRunning);
	assert.equal(snapshot.task, "fix docs");
	assert.equal(snapshot.status?.state, "booting");
	assert.equal(snapshot.launch, null);
	assert.equal(snapshot.statusParseError, undefined);
	assert.equal(typeof snapshot.launchParseError, "string");
});

test("loadWorkerSnapshot reads worker metadata from filesystem", async () => {
	const paths = await setupTempWorkerPaths();
	await writeWorkerFiles(paths, {
		launchFileText: JSON.stringify({ task: "fix auth", launchedAt: "2026-04-06T00:00:00Z" }),
		statusFileText: JSON.stringify({ task: "fix auth", state: "implementing", summary: "Touch auth module" }),
		eventLogFileText: [
			JSON.stringify({ type: "tool_execution_start", toolName: "read", args: { path: "src/auth.ts" } }),
			JSON.stringify({
				type: "message_end",
				message: { role: "assistant", content: [{ type: "text", text: "Updated auth handling" }] },
			}),
		].join("\n"),
		stderrFileText: "warn one\nwarn two\n",
		exitCodeText: "0\n",
		pidText: "123\n",
	});

	const assumeRunning = false;
	const snapshot = await loadWorkerSnapshot(paths, assumeRunning);
	assert.equal(snapshot.task, "fix auth");
	assert.equal(snapshot.isRunning, false);
	assert.equal(snapshot.exitCode, 0);
	assert.equal(snapshot.pid, 123);
	assert.equal(snapshot.status?.state, "implementing");
	assert.deepEqual(snapshot.recentEvents, ["read: src/auth.ts", "assistant: Updated auth handling"]);
	assert.equal(snapshot.stderrTail, "warn one\nwarn two");
});
