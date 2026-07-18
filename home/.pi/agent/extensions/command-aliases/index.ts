import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const CLEAR_COMMAND = "/clear";
const MEMORY_CLEAR_COMMAND = "/memory clear";

export default function commandAliases(pi: ExtensionAPI) {
	pi.on("input", (event) => {
		const text = event.text.trim() === CLEAR_COMMAND ? MEMORY_CLEAR_COMMAND : undefined;
		return text === undefined ? undefined : { text };
	});
}
