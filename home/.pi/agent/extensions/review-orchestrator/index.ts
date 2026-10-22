import { complete, type Message } from "@mariozechner/pi-ai";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import path from "node:path";
import {
	loadTarget,
	loadTemplate,
	normalizeScopeKind,
	parseScope,
	runReview,
	type ReviewCategory,
	type ReviewProgress,
} from "./core.ts";

const REVIEW_CATEGORIES: ReviewCategory[] = [
	{ id: "security", title: "Security", file: "security-review.md" },
	{ id: "correctness", title: "Correctness", file: "correctness-review.md" },
	{ id: "error-handling", title: "Error Handling / Recovery", file: "error-handling-review.md" },
	{ id: "testing", title: "Testing", file: "testing-review.md" },
	{ id: "behavioral-testing", title: "Behavioral Testing", file: "behavioral-testing-review.md" },
	{ id: "readability", title: "Readability", file: "readability-review.md" },
	{ id: "factoring", title: "Factoring", file: "factoring-review.md" },
	{ id: "maintainability", title: "Maintainability", file: "maintainability-review.md" },
	{ id: "canonical-language", title: "Canonical Language / Tooling", file: "canonical-language-review.md" },
	{ id: "declarative-ownership", title: "Declarative Ownership", file: "declarative-ownership-review.md" },
	{ id: "domain-logic", title: "Domain Logic", file: "domain-logic-review.md" },
	{ id: "performance", title: "Performance", file: "performance-review.md" },
	{ id: "concurrency", title: "Concurrency", file: "concurrency-review.md" },
	{ id: "docs", title: "Documentation", file: "docs-review.md" },
	{ id: "observability", title: "Observability / Logging", file: "observability-review.md" },
	{ id: "technical-writing", title: "Technical Writing", file: "technical-writing-review.md" },
	{ id: "commit-message", title: "Commit Message", file: "commit-message-review.md" },
	{ id: "whats-missing", title: "What's Missing", file: "whats-missing-review.md" },
	{ id: "history", title: "History / Precedent", file: "history-review.md" },
	{ id: "api", title: "API Design", file: "api-review.md" },
	{ id: "naming", title: "Naming", file: "naming-review.md" },
	{ id: "simple-names", title: "Simple Names", file: "simple-names-review.md" },
];

export default function reviewOrchestrator(pi: ExtensionAPI) {
	pi.registerCommand("review", {
		description: "Run a multi-pass code review (default scope comes from prompts/review.md)",
		handler: async (args, ctx) => {
			if (!ctx.model) {
				ctx.ui.notify("No model selected", "error");
				return;
			}

			try {
				const aggregateTemplate = await loadTemplate(ctx.cwd, "review.md");
				if (!aggregateTemplate) {
					ctx.ui.notify("Missing review.md template", "error");
					return;
				}

				const planTemplate = await loadTemplate(ctx.cwd, "review-plan.md");
				if (!planTemplate) {
					ctx.ui.notify("Missing review-plan.md template", "error");
					return;
				}

				const sharedSubReviewTemplate = await loadTemplate(ctx.cwd, path.join("review-prompts", "_shared.md"));
				if (!sharedSubReviewTemplate) {
					ctx.ui.notify("Missing review-prompts/_shared.md template", "error");
					return;
				}

				const defaultScope = normalizeScopeKind(aggregateTemplate.frontmatter["default-scope"] ?? "staged");
				const scopeHelp =
					aggregateTemplate.frontmatter["scope-help"] ??
					"uncommitted | staged | repo | range <git-revset> | file <path> | commit [<git-rev>] | head";

				const scope = parseScope(args, defaultScope);
				if (!scope) {
					ctx.ui.notify(`Usage: /review [${scopeHelp}]`, "error");
					return;
				}

				const target = await loadTarget(ctx.cwd, scope, {
					exec: (command, commandArgs, cwd) => execOrThrow(pi, command, commandArgs, cwd),
				});
				if (!target) {
					ctx.ui.notify("Nothing to review for that scope", "error");
					return;
				}

				const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model);
				if (!auth.ok || !auth.apiKey) {
					ctx.ui.notify(auth.ok ? "No API key available for current model" : auth.error, "error");
					return;
				}

				const requestOptions = {
					apiKey: auth.apiKey,
					headers: auth.headers,
				};

				ctx.ui.notify(`Starting multi-pass review for ${target.targetName}`, "info");

				const subReviewTemplates = await Promise.all(
					REVIEW_CATEGORIES.map(async (category) => {
						const template = await loadTemplate(ctx.cwd, path.join("review-prompts", category.file));
						if (!template) {
							throw new Error(`Missing review prompt: ${category.file}`);
						}
						return { category, template };
					}),
				);

				const { subReviews, aggregatedReview: finalReport, implementationPlan } = await runReview({
					target,
					templates: {
						sharedSubReview: sharedSubReviewTemplate,
						subReviews: subReviewTemplates,
						aggregate: aggregateTemplate,
						plan: planTemplate,
					},
					complete: ({ systemPrompt, prompt }) =>
						complete(ctx.model, { systemPrompt, messages: [toUserMessage(prompt)] }, requestOptions),
					onProgress: (progress) => ctx.ui.setStatus("review", reviewStatus(progress)),
				});

				pi.sendMessage(
					{
						customType: "review-report",
						content: [
							`# Multi-pass review: ${target.targetName}`,
							"",
							`Scope: ${target.reviewScope}`,
							`Details: ${target.scopeDescription}`,
							"",
							"## Stage 1: Aggregated review",
							"",
							finalReport,
							"",
							"## Stage 2: Change plan",
							"",
							implementationPlan,
							"",
							"## Review passes",
							...subReviews.flatMap((r) => [`- ${r.category.title}: ${r.templatePath}`]),
						].join("\n"),
						display: true,
						details: {
							target,
							subReviews,
							aggregatedReview: finalReport,
							implementationPlan,
							aggregateTemplatePath: aggregateTemplate.path,
							planTemplatePath: planTemplate.path,
							sharedSubReviewTemplatePath: sharedSubReviewTemplate.path,
						},
					},
					{ triggerTurn: false },
				);

				ctx.ui.notify(`Finished review for ${target.targetName}`, "success");
			} catch (error) {
				console.error("review command failed:", error);
				const message = error instanceof Error ? error.message : String(error);
				ctx.ui.notify(`Review failed: ${message}`, "error");
			} finally {
				ctx.ui.setStatus("review", "");
			}
		},
	});
}

function reviewStatus(progress: ReviewProgress): string {
	switch (progress.stage) {
		case "sub-reviews":
			return `Running ${progress.total} specialized review passes in parallel (${progress.completed}/${progress.total})`;
		case "aggregate":
			return "Aggregating review findings";
		case "plan":
			return "Planning coherent change order";
	}
}

function toUserMessage(text: string): Message {
	return {
		role: "user",
		content: [{ type: "text", text }],
		timestamp: Date.now(),
	};
}

async function execOrThrow(pi: ExtensionAPI, command: string, args: string[], cwd: string) {
	const result = await pi.exec(command, args, { cwd });
	if (result.code !== 0) {
		throw new Error(`${command} ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
	return result;
}
