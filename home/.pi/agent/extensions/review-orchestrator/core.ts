import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

export type ScopeKind = "staged" | "uncommitted" | "repo" | "range" | "file" | "commit";

export type ScopeSpec =
	| { kind: "staged" }
	| { kind: "uncommitted" }
	| { kind: "repo" }
	| { kind: "range"; value: string }
	| { kind: "file"; value: string }
	| { kind: "commit"; value: string };

export type TemplateInfo = {
	body: string;
	frontmatter: Record<string, string>;
	path: string;
};

export type LoadedTarget = {
	targetName: string;
	reviewScope: string;
	scopeDescription: string;
	content: string;
	gitHistoryContext: string;
};

type BaseLoadedTarget = Omit<LoadedTarget, "gitHistoryContext">;

export type TextContentItem = { type: string; text?: string };
export type CommandExecutor = (
	command: string,
	args: string[],
	cwd: string,
) => Promise<{ stdout: string; stderr: string }>;
export type TextFileReader = (filePath: string) => Promise<string>;

export const MAX_REVIEW_CHARS = 120_000;
export const MAX_REPO_FILES = 200;
export const MAX_GIT_HISTORY_CHARS = 12_000;

const GIT_HISTORY_RECORD_SEPARATOR = "\u001e";
const GIT_HISTORY_FIELD_SEPARATOR = "\u001f";
const MAX_GIT_HISTORY_COMMITS = 10;
const MAX_GIT_HISTORY_FILES = 20;
const MAX_GIT_HISTORY_FILES_PER_COMMIT = 12;
const NO_GIT_HISTORY_CONTEXT = "No focused git history context available for this review scope.";

type GitHistoryCommit = {
	hash: string;
	subject: string;
	touchedFiles: string[];
	matchedFiles: string[];
};

export function extractText(content: TextContentItem[]): string {
	return content
		.filter((item): item is { type: "text"; text: string } => item.type === "text" && typeof item.text === "string")
		.map((item) => item.text)
		.join("\n");
}

function normalizeCommitRevision(value: string): string {
	return value.replace(/^head(?=$|[~^])/i, "HEAD");
}

export function normalizeScopeKind(value: string): ScopeKind {
	switch ((value || "").trim().toLowerCase()) {
		case "working":
		case "uncommitted":
			return "uncommitted";
		case "repo":
		case "range":
		case "file":
		case "commit":
			return value.trim().toLowerCase() as ScopeKind;
		case "head":
			return "commit";
		default:
			return "staged";
	}
}

export function parseScope(args: string, defaultScope: ScopeKind): ScopeSpec | null {
	const trimmed = args.trim();
	const lowered = trimmed.toLowerCase();
	if (!trimmed) return defaultScope === "commit" ? { kind: "commit", value: "HEAD" } : { kind: defaultScope };
	if (lowered === "staged") return { kind: "staged" };
	if (lowered === "working" || lowered === "uncommitted") return { kind: "uncommitted" };
	if (lowered === "repo") return { kind: "repo" };
	if (lowered === "commit" || lowered === "head") return { kind: "commit", value: "HEAD" };
	if (lowered.startsWith("range ")) {
		const value = trimmed.slice(trimmed.indexOf(" ") + 1).trim();
		return value ? { kind: "range", value } : null;
	}
	if (lowered.startsWith("file ")) {
		const value = trimmed.slice(trimmed.indexOf(" ") + 1).trim();
		return value ? { kind: "file", value } : null;
	}
	if (lowered.startsWith("commit ")) {
		const value = trimmed.slice(trimmed.indexOf(" ") + 1).trim();
		return value ? { kind: "commit", value: normalizeCommitRevision(value) } : null;
	}
	if (/^head(?:$|[~^])/i.test(trimmed)) {
		return { kind: "commit", value: normalizeCommitRevision(trimmed) };
	}
	return null;
}

export async function loadTemplate(cwd: string, relativePath: string, homeDir = os.homedir()): Promise<TemplateInfo | null> {
	const candidates = [
		path.join(cwd, ".pi", "prompts", relativePath),
		path.join(homeDir, ".pi", "agent", "prompts", relativePath),
	];

	for (const candidate of candidates) {
		try {
			const raw = await fs.readFile(candidate, "utf8");
			const { frontmatter, body } = splitFrontmatter(raw);
			return { frontmatter, body, path: candidate };
		} catch {
			// Try next candidate.
		}
	}

	return null;
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

export function renderTemplate(template: string, values: Record<string, string>): string {
	let output = template;
	for (const [key, value] of Object.entries(values)) {
		output = output.replaceAll(`{{${key}}}`, value);
	}
	return output;
}

export async function loadTarget(
	cwd: string,
	scope: ScopeSpec,
	{
		exec,
		readTextFile: readTextFileImpl = readTextFile,
	}: { exec: CommandExecutor; readTextFile?: TextFileReader },
): Promise<LoadedTarget | null> {
	switch (scope.kind) {
		case "staged": {
			const diff = await exec("git", ["diff", "--cached", "--no-ext-diff", "--minimal"], cwd);
			const content = truncateForReview(diff.stdout.trim());
			if (!content) return null;
			const focusedFiles = await listGitPaths(exec, cwd, ["diff", "--cached", "--name-only"]);
			return {
				targetName: "staged changes",
				reviewScope: "staged",
				scopeDescription: "Git diff of staged changes only.",
				content,
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, focusedFiles }),
			};
		}
		case "uncommitted": {
			const target = await loadUncommittedTarget(cwd, { exec, readTextFile: readTextFileImpl });
			if (!target) return null;
			const focusedFiles = await listGitPaths(exec, cwd, ["diff", "--name-only", "HEAD"]);
			const untrackedFiles = await listGitPaths(exec, cwd, ["ls-files", "--others", "--exclude-standard"]);
			return {
				...target,
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, focusedFiles, untrackedFiles }),
			};
		}
		case "range": {
			const diff = await exec("git", ["diff", scope.value, "--no-ext-diff", "--minimal"], cwd);
			const content = truncateForReview(diff.stdout.trim());
			if (!content) return null;
			const focusedFiles = await listGitPaths(exec, cwd, ["diff", "--name-only", scope.value]);
			return {
				targetName: `range ${scope.value}`,
				reviewScope: `range ${scope.value}`,
				scopeDescription: `Git diff for revision range ${scope.value}.`,
				content,
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, focusedFiles }),
			};
		}
		case "commit": {
			const shown = await exec(
				"git",
				["show", "--format=medium", "--patch", "--no-ext-diff", "--minimal", scope.value],
				cwd,
			);
			const content = truncateForReview(shown.stdout.trim());
			if (!content) return null;
			const focusedFiles = await listGitPaths(exec, cwd, ["show", "--format=", "--name-only", scope.value]);
			return {
				targetName: `commit ${scope.value}`,
				reviewScope: `commit ${scope.value}`,
				scopeDescription: `Single commit review for ${scope.value}, including commit metadata and patch.`,
				content,
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, focusedFiles }),
			};
		}
		case "file": {
			const root = await fs.realpath(cwd);
			const filePath = await resolveReviewFilePath(root, scope.value);
			const raw = await readTextFileImpl(filePath);
			const relativePath = path.relative(root, filePath) || path.basename(filePath);
			return {
				targetName: relativePath,
				reviewScope: `file ${scope.value}`,
				scopeDescription: `Single file review for ${filePath}.`,
				content: truncateForReview(raw),
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, focusedFiles: [relativePath] }),
			};
		}
		case "repo": {
			const target = await loadRepoTarget(cwd, { exec, readTextFile: readTextFileImpl });
			if (!target) return null;
			return {
				...target,
				gitHistoryContext: await loadGitHistoryContext(cwd, { exec, repoWide: true }),
			};
		}
	}
}

export async function loadRepoTarget(
	cwd: string,
	{
		exec,
		readTextFile: readTextFileImpl = readTextFile,
	}: { exec: CommandExecutor; readTextFile?: TextFileReader },
): Promise<BaseLoadedTarget | null> {
	const listed = await exec("git", ["ls-files"], cwd);
	const files = listed.stdout
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean)
		.slice(0, MAX_REPO_FILES);
	if (files.length === 0) return null;

	let total = 0;
	let truncated = false;
	const chunks: string[] = [];
	for (const rel of files) {
		const fullPath = path.join(cwd, rel);
		let text: string;
		try {
			text = await readTextFileImpl(fullPath);
		} catch {
			continue;
		}
		const chunk = `## File: ${rel}\n\n${text}`;
		const separatorLength = chunks.length > 0 ? 2 : 0;
		if (total + separatorLength + chunk.length > MAX_REVIEW_CHARS) {
			if (chunks.length === 0) {
				chunks.push(
					truncateToBudget(chunk, MAX_REVIEW_CHARS, "Repo review input truncated to stay within prompt budget."),
				);
				total = chunks[0].length;
			}
			truncated = true;
			break;
		}
		chunks.push(chunk);
		total += separatorLength + chunk.length;
	}
	if (chunks.length === 0) return null;

	let content = chunks.join("\n\n");
	if (truncated) {
		const note = `[Truncated repo review input after ${chunks.length} files to stay within prompt budget.]`;
		const separator = content ? "\n\n" : "";
		const remaining = MAX_REVIEW_CHARS - content.length - separator.length;
		if (remaining > 0) {
			content = `${content}${separator}${truncateToBudget(note, remaining, "Additional repo truncation details were truncated.")}`;
		}
	}

	return {
		targetName: "repository tree",
		reviewScope: "repo",
		scopeDescription: "Tracked repository files from the current tree, truncated to fit prompt budget.",
		content,
	};
}

export async function loadUncommittedTarget(
	cwd: string,
	{
		exec,
		readTextFile: readTextFileImpl = readTextFile,
	}: { exec: CommandExecutor; readTextFile?: TextFileReader },
): Promise<BaseLoadedTarget | null> {
	const diff = await exec("git", ["diff", "HEAD", "--no-ext-diff", "--minimal"], cwd);
	const trackedDiff = diff.stdout.trim();

	const untracked = await exec("git", ["ls-files", "--others", "--exclude-standard"], cwd);
	const untrackedFiles = untracked.stdout
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean);

	const sections: string[] = [];

	if (trackedDiff) {
		const header = "## Tracked changes (diff vs HEAD)\n\n";
		const diffBudget = untrackedFiles.length > 0 ? Math.floor(MAX_REVIEW_CHARS * 0.75) : MAX_REVIEW_CHARS;
		sections.push(
			`${header}${truncateToBudget(trackedDiff, Math.max(0, diffBudget - header.length), "Tracked diff truncated to stay within review budget.")}`,
		);
	}

	const omittedUntracked: string[] = [];
	let content = sections.join("\n\n");
	for (const rel of untrackedFiles) {
		let text: string;
		try {
			text = await readTextFileImpl(path.join(cwd, rel));
		} catch {
			omittedUntracked.push(`${rel} (binary or unreadable)`);
			continue;
		}

		const chunk = `## Untracked file: ${rel}\n\n${text}`;
		const nextContent = [content, chunk].filter(Boolean).join("\n\n");
		if (nextContent.length > MAX_REVIEW_CHARS) {
			omittedUntracked.push(rel);
			continue;
		}
		content = nextContent;
	}

	if (omittedUntracked.length > 0) {
		const listed = omittedUntracked.slice(0, 20).map((rel) => `- ${rel}`).join("\n");
		const more = omittedUntracked.length > 20 ? `\n- ...and ${omittedUntracked.length - 20} more` : "";
		const note = `## Omitted untracked files\n\n${listed}${more}\n\n[Some untracked files were omitted to stay within review budget.]`;
		if (content) {
			const separator = "\n\n";
			const remaining = MAX_REVIEW_CHARS - content.length - separator.length;
			if (remaining > 0) {
				content = `${content}${separator}${truncateToBudget(note, remaining, "Additional omitted untracked-file details were truncated.")}`;
			}
		} else {
			content = truncateToBudget(note, MAX_REVIEW_CHARS, "Additional omitted untracked-file details were truncated.");
		}
	}

	const finalContent = content.trim();
	if (!finalContent) return null;

	return {
		targetName: "uncommitted changes",
		reviewScope: "uncommitted",
		scopeDescription: "Tracked changes against HEAD plus non-ignored untracked files.",
		content: finalContent,
	};
}

export async function loadGitHistoryContext(
	cwd: string,
	{
		exec,
		focusedFiles = [],
		untrackedFiles = [],
		repoWide = false,
	}: {
		exec: CommandExecutor;
		focusedFiles?: string[];
		untrackedFiles?: string[];
		repoWide?: boolean;
	},
): Promise<string> {
	const uniqueFocusedFiles = dedupeStrings(focusedFiles);
	const uniqueUntrackedFiles = dedupeStrings(untrackedFiles);
	const limitedFocusedFiles = uniqueFocusedFiles.slice(0, MAX_GIT_HISTORY_FILES);
	const sections: string[] = [];

	if (uniqueFocusedFiles.length > 0) {
		sections.push(["Focused files in review scope:", ...formatBullets(uniqueFocusedFiles, MAX_GIT_HISTORY_FILES)].join("\n"));
	}

	if (uniqueUntrackedFiles.length > 0) {
		sections.push(
			[
				"Untracked files in review scope (no git history yet):",
				...formatBullets(uniqueUntrackedFiles, MAX_GIT_HISTORY_FILES),
			].join("\n"),
		);
	}

	let commits: GitHistoryCommit[] = [];
	if (repoWide || limitedFocusedFiles.length > 0) {
		try {
			commits = await loadGitHistoryCommits(cwd, exec, repoWide ? [] : limitedFocusedFiles);
		} catch {
			commits = [];
		}
	}

	if (commits.length > 0) {
		sections.push(formatGitHistoryCommits(commits, { repoWide }));
	} else if (repoWide || uniqueFocusedFiles.length > 0) {
		sections.push("No relevant git history found for this review scope.");
	}

	if (sections.length === 0) return NO_GIT_HISTORY_CONTEXT;

	return truncateToBudget(
		sections.join("\n\n"),
		MAX_GIT_HISTORY_CHARS,
		`Git history context truncated to ${MAX_GIT_HISTORY_CHARS} characters.`,
	);
}

async function loadGitHistoryCommits(
	cwd: string,
	exec: CommandExecutor,
	focusedFiles: string[],
): Promise<GitHistoryCommit[]> {
	const args = [
		"log",
		"--no-merges",
		`--format=${GIT_HISTORY_RECORD_SEPARATOR}%h${GIT_HISTORY_FIELD_SEPARATOR}%s`,
		"--name-only",
		"-n",
		String(MAX_GIT_HISTORY_COMMITS),
	];
	if (focusedFiles.length > 0) args.push("--", ...focusedFiles);
	const history = await exec("git", args, cwd);
	return parseGitHistoryCommits(history.stdout, new Set(focusedFiles));
}

function parseGitHistoryCommits(raw: string, focusedFiles: ReadonlySet<string>): GitHistoryCommit[] {
	return raw
		.split(GIT_HISTORY_RECORD_SEPARATOR)
		.map((chunk) => chunk.trim())
		.filter(Boolean)
		.map((chunk) => {
			const [header = "", ...fileLines] = chunk.split("\n");
			const [hash = "", subject = ""] = header.split(GIT_HISTORY_FIELD_SEPARATOR);
			const touchedFiles = dedupeStrings(fileLines.map((line) => line.trim()).filter(Boolean));
			return {
				hash: hash.trim(),
				subject: subject.trim(),
				touchedFiles,
				matchedFiles: touchedFiles.filter((file) => focusedFiles.has(file)),
			};
		})
		.filter((commit) => commit.hash && commit.subject);
}

function formatGitHistoryCommits(commits: GitHistoryCommit[], { repoWide }: { repoWide: boolean }): string {
	const lines = [repoWide ? "Repository-wide recent commits:" : "Recent related commits:"];
	for (const commit of commits) {
		lines.push(`- ${commit.hash} | ${commit.subject}`);
		if (!repoWide && commit.matchedFiles.length > 0) {
			lines.push("  matched current files:");
			lines.push(...formatBullets(commit.matchedFiles, MAX_GIT_HISTORY_FILES_PER_COMMIT, "  "));
		}
		if (commit.touchedFiles.length > 0) {
			lines.push("  touched files in commit:");
			lines.push(...formatBullets(commit.touchedFiles, MAX_GIT_HISTORY_FILES_PER_COMMIT, "  "));
		}
	}
	return lines.join("\n");
}

async function listGitPaths(exec: CommandExecutor, cwd: string, args: string[]): Promise<string[]> {
	const result = await exec("git", args, cwd);
	return dedupeStrings(result.stdout.split("\n").map((line) => line.trim()).filter(Boolean));
}

function dedupeStrings(values: string[]): string[] {
	return Array.from(new Set(values.filter(Boolean)));
}

function formatBullets(items: string[], maxItems: number, indent = ""): string[] {
	const lines = items.slice(0, maxItems).map((item) => `${indent}- ${item}`);
	if (items.length > maxItems) {
		lines.push(`${indent}- ...and ${items.length - maxItems} more`);
	}
	return lines;
}

async function resolveReviewFilePath(cwd: string, value: string): Promise<string> {
	const root = await fs.realpath(cwd);
	const filePath = path.resolve(root, stripAtPrefix(value));
	if (!isPathWithinRoot(root, filePath)) {
		throw new Error(`File review path must stay within the current working directory: ${value}`);
	}

	const resolvedFilePath = await fs.realpath(filePath);
	if (!isPathWithinRoot(root, resolvedFilePath)) {
		throw new Error(`File review path must stay within the current working directory: ${value}`);
	}

	return filePath;
}

function isPathWithinRoot(root: string, candidate: string): boolean {
	const relative = path.relative(root, candidate);
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export function truncateToBudget(text: string, maxChars: number, note: string): string {
	if (text.length <= maxChars) return text;
	if (maxChars <= 0) return "";
	const suffix = `\n\n[${note}]`;
	if (suffix.length >= maxChars) return text.slice(0, maxChars);
	const available = maxChars - suffix.length;
	return `${text.slice(0, available)}${suffix}`;
}

export async function readTextFile(filePath: string): Promise<string> {
	const buffer = await fs.readFile(filePath);
	if (buffer.includes(0)) {
		throw new Error("Binary file");
	}
	return buffer.toString("utf8");
}

export function truncateForReview(text: string): string {
	return truncateToBudget(text, MAX_REVIEW_CHARS, `Truncated to ${MAX_REVIEW_CHARS} characters for review.`);
}

// Support `file @path` because pi file references often include a leading marker.
export function stripAtPrefix(value: string): string {
	return value.startsWith("@") ? value.slice(1) : value;
}
