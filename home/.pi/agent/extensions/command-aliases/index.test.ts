import { expect, test } from "bun:test";
import commandAliases from "./index.ts";

test("rewrites only /clear to the memory clear command", () => {
	let inputHandler: ((event: { text: string }, context: unknown) => unknown) | undefined;
	commandAliases({
		on(event: string, handler: typeof inputHandler) {
			expect(event).toBe("input");
			inputHandler = handler;
		},
	} as never);

	expect(inputHandler).toBeDefined();
	expect(inputHandler?.({ text: "/clear" }, {})).toEqual({ text: "/memory clear" });
	expect(inputHandler?.({ text: "  /clear  " }, {})).toEqual({ text: "/memory clear" });
	expect(inputHandler?.({ text: "/clear now" }, {})).toBeUndefined();
	expect(inputHandler?.({ text: "/memory clear" }, {})).toBeUndefined();
});
