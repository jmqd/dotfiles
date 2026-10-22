import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import phone from "./index.ts";

// Limits the companion enforces on every snapshot (src/sessions.rs `Session::valid`
// and the extension socket's LinesCodec in src/main.rs). Byte limits count UTF-8.
const MAX_LINE_BYTES = 1024 * 1024;
const MAX_TITLE_BYTES = 1024;
const MAX_CWD_BYTES = 4096;
const MAX_MESSAGES = 2048;

// Whichever unit a cut lands on, one of each pair splits an emoji there.
const emoji = "😀".repeat(7000);
const shiftedEmoji = `a${emoji}`;

function strings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (value === null || typeof value !== "object") return [];
  return Object.values(value).flatMap(strings);
}

// The companion parses each line with serde_json into Rust `String`s and drops
// the session when a line does not parse or the session is invalid.
function assertCompanionAccepts(line: string, sessionName: string): void {
  assert.ok(Buffer.byteLength(line) <= MAX_LINE_BYTES, "frame exceeds the companion's line limit");
  const frame = JSON.parse(line);
  assert.equal(frame.type, "snapshot");
  for (const text of strings(frame)) {
    assert.ok(text.isWellFormed(), `lone surrogate near ${JSON.stringify(text.slice(-8))}`);
  }
  const { session } = frame;
  assert.match(session.id, /^[A-Za-z0-9_-]{1,128}$/);
  assert.ok(session.title, "title is empty");
  assert.ok(sessionName.startsWith(session.title), "title is not a prefix of the session name");
  assert.ok(Buffer.byteLength(session.title) <= MAX_TITLE_BYTES, "title exceeds the companion's limit");
  assert.ok(Buffer.byteLength(session.cwd) <= MAX_CWD_BYTES, "cwd exceeds the companion's limit");
  assert.ok(session.messages.length <= MAX_MESSAGES, "too many messages");
}

test("a long session with emoji stays on the phone", { timeout: 10_000 }, async t => {
  // Undo in reverse: the extension must hang up before the companion can close.
  const cleanup: (() => unknown)[] = [];
  t.after(async () => { for (const step of cleanup.reverse()) await step(); });
  const stateDir = await mkdtemp(join(tmpdir(), "omp-phone-"));
  cleanup.push(() => rm(stateDir, { recursive: true, force: true }));

  // Fake companion: collect every line the extension sends.
  const lines: string[] = [];
  let wake = (): void => {};
  const companion = createServer(socket => {
    socket.setEncoding("utf8");
    let buffered = "";
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      let end: number;
      while ((end = buffered.indexOf("\n")) !== -1) {
        lines.push(buffered.slice(0, end));
        buffered = buffered.slice(end + 1);
      }
      wake();
    });
  });
  const listening = Promise.withResolvers<void>();
  companion.listen(join(stateDir, "extension.sock"), listening.resolve);
  await listening.promise;
  cleanup.push(() => {
    const closed = Promise.withResolvers<void>();
    companion.close(() => closed.resolve());
    return closed.promise;
  });
  let received = 0;
  async function nextLine(): Promise<string> {
    while (lines.length <= received) {
      const arrived = Promise.withResolvers<void>();
      wake = arrived.resolve;
      await arrived.promise;
    }
    return lines[received++]!;
  }

  // The extension only shares interactive terminal sessions.
  const tty = process.stdin.isTTY;
  process.stdin.isTTY = true;
  cleanup.push(() => { process.stdin.isTTY = tty; });
  const env = { ...process.env };
  process.env.OMP_PHONE_STATE_DIR = stateDir;
  delete process.env.OMP_PHONE_DISABLED;
  cleanup.push(() => { process.env = env; });

  // Fake OMP host: only the events and methods the extension uses.
  const handlers = new Map<string, (event: unknown, context: unknown) => void>();
  let sessionName = `a${"😀".repeat(300)}`;
  const ticks: (() => void)[] = [];
  const context = {
    hasUI: true,
    cwd: `/home/user/${"📁".repeat(1100)}`,
    sessionManager: {
      getSessionId: () => "session-1",
      getBranch: () => [
        { type: "message", message: { role: "user", content: emoji } },
        { type: "message", message: { role: "assistant", content: [{ type: "text", text: shiftedEmoji }] } },
      ],
    },
    isIdle: () => true,
    hasPendingMessages: () => false,
    setInterval: (tick: () => void) => { ticks.push(tick); },
    abort: async () => {},
    ui: { notify: () => {} },
  };
  const host = {
    on: (event: string, handler: (event: unknown, context: unknown) => void) => { handlers.set(event, handler); },
    getSessionName: () => sessionName,
    sendUserMessage: () => {},
    registerCommand: () => {},
  };
  const emit = (event: string, payload: unknown = {}): void => handlers.get(event)!(payload, context);
  phone(host as unknown as Parameters<typeof phone>[0]);
  cleanup.push(() => emit("session_shutdown"));

  emit("session_start");
  const first = await nextLine();
  assertCompanionAccepts(first, sessionName);
  assert.equal(JSON.parse(first).session.messages.length, 2);

  for (const text of [emoji, shiftedEmoji]) {
    emit("message_update", { message: { role: "assistant", content: [{ type: "text", text }] } });
    emit("agent_start");
    const line = await nextLine();
    assertCompanionAccepts(line, sessionName);
    assert.ok(JSON.parse(line).session.partial, "partial reply is empty");
  }

  for (const [text, name] of [[emoji, `ab${"😀".repeat(300)}`], [shiftedEmoji, "😀".repeat(300)]] as const) {
    emit("message_end", { message: { role: "toolResult", toolName: "read", content: text } });
    sessionName = name;
    for (const tick of ticks) tick();
    assertCompanionAccepts(await nextLine(), sessionName);
  }
});
