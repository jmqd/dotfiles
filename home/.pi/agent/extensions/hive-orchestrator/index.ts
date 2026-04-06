import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const baseDir = dirname(fileURLToPath(import.meta.url));

export default function hiveOrchestrator(pi: ExtensionAPI) {
	pi.on("resources_discover", () => {
		return {
			promptPaths: [
				join(baseDir, "prompts", "hive-orchestrator.md"),
				join(baseDir, "prompts", "hive-worker.md"),
			],
			skillPaths: [join(baseDir, "skills", "hive-swarm", "SKILL.md")],
		};
	});
}
