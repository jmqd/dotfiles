import assert from "node:assert/strict";
import { mkdtemp, realpath, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
	extractText,
	loadRepoTarget,
	loadTarget,
	loadUncommittedTarget,
	MAX_REVIEW_CHARS,
	normalizeScopeKind,
	parseScope,
	renderTemplate,
	splitFrontmatter,
	stripAtPrefix,
	truncateForReview,
	truncateToBudget,
	type CommandExecutor,
} from "./core.ts";

function createExec(responses: Record<string, { stdout: string; stderr?: string }>): CommandExecutor {
	return async (command, args, cwd) => {
		void cwd;
		const key = `${command} ${args.join(" ")}`;
		const response = responses[key];
		assert.ok(response, `Unexpected exec call: ${key}`);
		return { stdout: response.stdout, stderr: response.stderr ?? "" };
	};
}

test("normalizeScopeKind maps aliases and defaults unknown values to staged", () => {
	assert.equal(normalizeScopeKind("working"), "uncommitted");
	assert.equal(normalizeScopeKind("uncommitted"), "uncommitted");
	assert.equal(normalizeScopeKind("repo"), "repo");
	assert.equal(normalizeScopeKind("range"), "range");
	assert.equal(normalizeScopeKind("file"), "file");
	assert.equal(normalizeScopeKind(" staged "), "staged");
	assert.equal(normalizeScopeKind(""), "staged");
	assert.equal(normalizeScopeKind("nonsense"), "staged");
});

test("parseScope handles supported scopes and aliases", () => {
	assert.deepEqual(parseScope("", "repo"), { kind: "repo" });
	assert.deepEqual(parseScope("staged", "repo"), { kind: "staged" });
	assert.deepEqual(parseScope("working", "staged"), { kind: "uncommitted" });
	assert.deepEqual(parseScope("uncommitted", "staged"), { kind: "uncommitted" });
	assert.deepEqual(parseScope("repo", "staged"), { kind: "repo" });
	assert.deepEqual(parseScope("range HEAD~3..HEAD", "staged"), { kind: "range", value: "HEAD~3..HEAD" });
	assert.deepEqual(parseScope("file src/main.ts", "staged"), { kind: "file", value: "src/main.ts" });
	assert.deepEqual(parseScope("file @src/main.ts", "staged"), { kind: "file", value: "@src/main.ts" });
	assert.equal(parseScope("range", "staged"), null);
	assert.equal(parseScope("range   ", "staged"), null);
	assert.equal(parseScope("file", "staged"), null);
	assert.equal(parseScope("file   ", "staged"), null);
	assert.equal(parseScope("unknown", "staged"), null);
});

test("splitFrontmatter parses simple frontmatter and leaves malformed input alone", () => {
	assert.deepEqual(splitFrontmatter("plain body"), { frontmatter: {}, body: "plain body" });
	assert.deepEqual(splitFrontmatter("---\nkey: value\nother: keeps: colons\nignored\n---\nbody\n"), {
		frontmatter: { key: "value", other: "keeps: colons" },
		body: "body\n",
	});
	assert.deepEqual(splitFrontmatter("---\nkey: value\nbody without closer"), {
		frontmatter: {},
		body: "---\nkey: value\nbody without closer",
	});
});

test("renderTemplate replaces repeated placeholders and leaves unknown ones intact", () => {
	const rendered = renderTemplate("Hello {{NAME}}. Again: {{NAME}}. Missing: {{OTHER}}", { NAME: "pi" });
	assert.equal(rendered, "Hello pi. Again: pi. Missing: {{OTHER}}");
});

test("extractText concatenates only text content", () => {
	assert.equal(
		extractText([
			{ type: "text", text: "alpha" },
			{ type: "image", text: "ignored" },
			{ type: "text", text: "beta" },
		]),
		"alpha\nbeta",
	);
	assert.equal(extractText([]), "");
});

test("truncate helpers always stay within budget", () => {
	assert.equal(truncateToBudget("short", 10, "note"), "short");

	const truncated = truncateToBudget("abcdefghij", 8, "cut");
	assert.equal(truncated, "a\n\n[cut]");
	assert.ok(truncated.length <= 8);

	const tinyBudget = truncateToBudget("abcdefghij", 3, "cut");
	assert.equal(tinyBudget, "abc");
	assert.ok(tinyBudget.length <= 3);

	const reviewText = truncateForReview("x".repeat(MAX_REVIEW_CHARS + 50));
	assert.ok(reviewText.length <= MAX_REVIEW_CHARS);
	assert.match(reviewText, /Truncated to 120000 characters for review\./);
});

test("stripAtPrefix only removes a leading @ marker", () => {
	assert.equal(stripAtPrefix("@src/main.ts"), "src/main.ts");
	assert.equal(stripAtPrefix("src/@main.ts"), "src/@main.ts");
	assert.equal(stripAtPrefix("src/main.ts"), "src/main.ts");
});

test("loadTarget covers staged, range, in-repo file scope, and empty staged scopes", async () => {
	const cwd = await mkdtemp(path.join(os.tmpdir(), "review-target-"));
	const filePath = path.join(cwd, "notes.txt");
	await writeFile(filePath, "hello world\n", "utf8");

	const exec = createExec({
		"git diff --cached --no-ext-diff --minimal": { stdout: "diff --git a/a b/a\n" },
		"git diff HEAD~1..HEAD --no-ext-diff --minimal": { stdout: "diff --git a/range b/range\n" },
	});

	assert.deepEqual(await loadTarget(cwd, { kind: "staged" }, { exec }), {
		targetName: "staged changes",
		reviewScope: "staged",
		scopeDescription: "Git diff of staged changes only.",
		content: "diff --git a/a b/a",
	});

	assert.deepEqual(await loadTarget(cwd, { kind: "range", value: "HEAD~1..HEAD" }, { exec }), {
		targetName: "range HEAD~1..HEAD",
		reviewScope: "range HEAD~1..HEAD",
		scopeDescription: "Git diff for revision range HEAD~1..HEAD.",
		content: "diff --git a/range b/range",
	});

	const realFilePath = await realpath(filePath);
	let readPath: string | undefined;
	const fileTarget = await loadTarget(cwd, { kind: "file", value: "@notes.txt" }, {
		exec,
		readTextFile: async (requestedPath) => {
			readPath = requestedPath;
			return "injected file contents\n";
		},
	});
	assert.equal(readPath, realFilePath);
	assert.deepEqual(fileTarget, {
		targetName: "notes.txt",
		reviewScope: "file @notes.txt",
		scopeDescription: `Single file review for ${realFilePath}.`,
		content: "injected file contents\n",
	});

	const emptyExec = createExec({
		"git diff --cached --no-ext-diff --minimal": { stdout: "\n\n" },
	});
	assert.equal(await loadTarget(cwd, { kind: "staged" }, { exec: emptyExec }), null);
});

test("loadTarget file scope rejects paths outside cwd", async () => {
	const cwd = await mkdtemp(path.join(os.tmpdir(), "review-target-boundary-"));
	const exec = createExec({});

	await assert.rejects(
		() =>
			loadTarget(cwd, { kind: "file", value: "../outside.txt" }, {
				exec,
				readTextFile: async () => "should not be read",
			}),
		/must stay within the current working directory/,
	);

	await assert.rejects(
		() =>
			loadTarget(cwd, { kind: "file", value: path.join(os.tmpdir(), "outside.txt") }, {
				exec,
				readTextFile: async () => "should not be read",
			}),
		/must stay within the current working directory/,
	);
});

test("loadTarget file scope propagates injected reader errors", async () => {
	const cwd = await mkdtemp(path.join(os.tmpdir(), "review-target-reader-"));
	const filePath = path.join(cwd, "notes.txt");
	await writeFile(filePath, "placeholder\n", "utf8");
	const exec = createExec({});
	const realFilePath = await realpath(filePath);

	await assert.rejects(
		() =>
			loadTarget(cwd, { kind: "file", value: "notes.txt" }, {
				exec,
				readTextFile: async (requestedPath) => {
					assert.equal(requestedPath, realFilePath);
					throw new Error("Binary file");
				},
			}),
		/Binary file/,
	);
});

test("loadRepoTarget truncates oversized first files instead of returning null", async () => {
	const content = "x".repeat(MAX_REVIEW_CHARS + 500);
	const repoTarget = await loadRepoTarget("/repo", {
		exec: createExec({
			"git ls-files": { stdout: "big.txt\nsmall.txt\n" },
		}),
		readTextFile: async (filePath) => {
			if (filePath.endsWith("big.txt")) return content;
			return "small";
		},
	});

	assert.ok(repoTarget);
	assert.equal(repoTarget?.reviewScope, "repo");
	assert.ok(repoTarget!.content.length <= MAX_REVIEW_CHARS);
	assert.match(repoTarget!.content, /## File: big\.txt/);
	assert.match(repoTarget!.content, /Repo review input truncated to stay within prompt budget\./);
});

test("loadUncommittedTarget handles tracked-only changes", async () => {
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: "diff --git a/a b/a\n+tracked\n" },
			"git ls-files --others --exclude-standard": { stdout: "" },
		}),
	});

	assert.ok(target);
	assert.equal(target?.reviewScope, "uncommitted");
	assert.match(target!.content, /^## Tracked changes \(diff vs HEAD\)/);
	assert.doesNotMatch(target!.content, /## Untracked file:/);
	assert.doesNotMatch(target!.content, /## Omitted untracked files/);
});

test("loadUncommittedTarget handles untracked-only changes", async () => {
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: "" },
			"git ls-files --others --exclude-standard": { stdout: "one.txt\ntwo.txt\n" },
		}),
		readTextFile: async (filePath) => `contents for ${path.basename(filePath)}`,
	});

	assert.ok(target);
	assert.doesNotMatch(target!.content, /Tracked changes/);
	assert.match(target!.content, /## Untracked file: one\.txt/);
	assert.match(target!.content, /## Untracked file: two\.txt/);
});

test("loadUncommittedTarget marks unreadable files as omitted", async () => {
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: "" },
			"git ls-files --others --exclude-standard": { stdout: "bin.dat\n" },
		}),
		readTextFile: async () => {
			throw new Error("binary");
		},
	});

	assert.ok(target);
	assert.match(target!.content, /## Omitted untracked files/);
	assert.match(target!.content, /- bin\.dat \(binary or unreadable\)/);
});

test("loadUncommittedTarget splits prompt budget between tracked and untracked content", async () => {
	const trackedDiff = "d".repeat(MAX_REVIEW_CHARS);
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: trackedDiff },
			"git ls-files --others --exclude-standard": { stdout: "note.txt\n" },
		}),
		readTextFile: async () => "small note",
	});

	assert.ok(target);
	assert.ok(target!.content.length <= MAX_REVIEW_CHARS);
	assert.match(target!.content, /Tracked diff truncated to stay within review budget\./);
	assert.match(target!.content, /## Untracked file: note\.txt/);
});

test("loadUncommittedTarget omits oversized untracked files and caps the omitted list", async () => {
	const names = Array.from({ length: 25 }, (_, index) => `file-${index}.txt`);
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: "" },
			"git ls-files --others --exclude-standard": { stdout: `${names.join("\n")}\n` },
		}),
		readTextFile: async () => "x".repeat(MAX_REVIEW_CHARS),
	});

	assert.ok(target);
	assert.match(target!.content, /## Omitted untracked files/);
	assert.match(target!.content, /- file-0\.txt/);
	assert.match(target!.content, /- file-19\.txt/);
	assert.doesNotMatch(target!.content, /- file-20\.txt/);
	assert.match(target!.content, /- \.\.\.and 5 more/);
	assert.ok(target!.content.length <= MAX_REVIEW_CHARS);
});

test("loadUncommittedTarget truncates huge omitted-file notes to fit the prompt budget", async () => {
	const hugeNames = Array.from({ length: 25 }, (_, index) => `${index}-${"n".repeat(10_000)}.txt`);
	const target = await loadUncommittedTarget("/repo", {
		exec: createExec({
			"git diff HEAD --no-ext-diff --minimal": { stdout: "" },
			"git ls-files --others --exclude-standard": { stdout: `${hugeNames.join("\n")}\n` },
		}),
		readTextFile: async () => {
			throw new Error("unreadable");
		},
	});

	assert.ok(target);
	assert.ok(target!.content.length <= MAX_REVIEW_CHARS);
	assert.match(target!.content, /## Omitted untracked files/);
});
