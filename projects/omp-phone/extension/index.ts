import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { basename, join } from "node:path";

// This module runs in OMP's Bun runtime. The companion owns HTTP, auth and push;
// only this extension can deliver input to its existing, authoritative session.
interface PhoneMessage {
  role: "user" | "assistant" | "tool";
  text: string;
}

const MAX_MESSAGES = 200;
const MAX_TEXT = 12_000;
const MAX_TRANSCRIPT = 120_000;

function clipped(text: string): string {
  const suffix = "\n[Shortened — full output is in the terminal]";
  return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT - suffix.length) + suffix : text;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function messageText(value: unknown): string {
  const message = record(value);
  if (!message) return "";
  const content = message.content;
  if (typeof content === "string") return clipped(content);
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  let remaining = MAX_TEXT;
  for (const raw of content) {
    const block = record(raw);
    if (!block) continue;
    const text = block.type === "text" && typeof block.text === "string"
      ? block.text
      : block.type === "image" ? "[Image — view in terminal]"
      : block.type === "toolCall" && typeof block.name === "string" ? `Calling ${block.name}`
      : "";
    if (!text) continue;
    parts.push(text.slice(0, remaining + 1));
    remaining -= Math.min(text.length, remaining + 1) + 1;
    if (remaining <= 0) break;
  }
  return clipped(parts.join("\n"));
}

function phoneMessage(value: unknown): PhoneMessage | undefined {
  const message = record(value);
  if (!message) return;
  const role = message.role === "toolResult" ? "tool" : message.role;
  if (role !== "user" && role !== "assistant" && role !== "tool") return;
  let text = messageText(message);
  if (role === "tool") {
    text = `${typeof message.toolName === "string" ? message.toolName : "Tool"}${message.isError ? " (error)" : ""}\n${text}`;
  } else if (role === "assistant" && typeof message.errorMessage === "string") {
    text += `\n${clipped(message.errorMessage)}`;
  }
  return text ? { role, text: clipped(text) } : undefined;
}

export default function phone(pi: ExtensionAPI): void {
  const stateDir = process.env.OMP_PHONE_STATE_DIR ?? join(
    process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state"), "omp-phone",
  );
  let ctx: ExtensionContext | undefined;
  let socket: Socket | undefined;
  let stopped = true;
  let generation = 0;
  let connectStarted = 0;
  let nextConnect = 0;
  let state: "idle" | "working" = "idle";
  let messages: PhoneMessage[] = [];
  let partial = "";
  let dirty = false;
  let title = "";
  let sessionId = "";
  let lastError = "Companion not connected";

  function currentId(context: ExtensionContext): string {
    return `${process.pid}-${context.sessionManager.getSessionId()}`;
  }

  function trimMessages(): void {
    if (messages.length > MAX_MESSAGES) messages.splice(0, messages.length - MAX_MESSAGES);
    let size = 0;
    for (let i = messages.length - 1; i >= 0; i--) {
      size += messages[i]!.text.length;
      if (size > MAX_TRANSCRIPT) {
        messages.splice(0, i + 1);
        break;
      }
    }
  }

  function loadTranscript(): void {
    if (!ctx) return;
    messages = [];
    const branch = ctx.sessionManager.getBranch();
    // Walk backwards so a long terminal history does not get copied in full.
    let size = 0;
    for (let i = branch.length - 1; i >= 0 && messages.length < MAX_MESSAGES; i--) {
      const entry = branch[i]!;
      if (entry.type !== "message") continue;
      const message = phoneMessage(entry.message);
      if (!message) continue;
      size += message.text.length;
      if (size > MAX_TRANSCRIPT) break;
      messages.push(message);
    }
    messages.reverse();
    dirty = true;
  }

  function updateContext(context: ExtensionContext): void {
    ctx = context;
    sessionId = currentId(context);
    title = pi.getSessionName() || basename(context.cwd) || "OMP session";
    state = context.isIdle() ? "idle" : "working";
    partial = "";
    loadTranscript();
  }

  function flush(): void {
    if (!dirty || !ctx || socket?.readyState !== "open") return;
    if (socket.writableLength > 1_000_000) {
      socket.destroy();
      return;
    }
    socket.write(JSON.stringify({
      type: "snapshot",
      session: { id: sessionId, title, cwd: ctx.cwd, state, messages, partial },
    }) + "\n");
    dirty = false;
  }

  function report(error: unknown): void {
    lastError = error instanceof Error ? error.message : String(error);
    // Never log the token or the incoming prompt. Network callbacks are outside
    // OMP's event-handler isolation and must not throw into the host process.
  }

  async function command(raw: unknown, source: Socket): Promise<void> {
    const message = record(raw);
    if (!message || message.type !== "command" || typeof message.requestId !== "string") return;
    const requestId = message.requestId;
    try {
      if (stopped || source !== socket || !ctx || message.sessionId !== sessionId || currentId(ctx) !== sessionId) {
        throw new Error("Session no longer connected");
      }
      if (message.action === "prompt") {
        if (typeof message.text !== "string" || !message.text.trim() || message.text.length > 32_000) {
          throw new Error("Reply must contain 1–32000 characters");
        }
        pi.sendUserMessage(message.text, ctx.isIdle() ? undefined : { deliverAs: "followUp" });
      } else if (message.action === "abort") {
        await ctx.abort();
      } else {
        throw new Error("Unknown phone command");
      }
      if (source.readyState === "open") source.write(JSON.stringify({ type: "result", requestId, ok: true }) + "\n");
    } catch (error) {
      if (source.readyState === "open") {
        source.write(JSON.stringify({ type: "result", requestId, ok: false, error: error instanceof Error ? error.message : "Command failed" }) + "\n");
      }
    }
  }

  function connect(): void {
    if (stopped || socket || Date.now() < nextConnect) return;
    const epoch = generation;
    nextConnect = Date.now() + 5000;
    try {
      // The companion's 0600 Unix socket lives in its 0700 state directory.
      // Extension control has no HTTP endpoint and cannot be proxied by Serve.
      const client = createConnection(join(stateDir, "extension.sock"));
      client.setEncoding("utf8");
      socket = client;
      connectStarted = Date.now();
      let incoming = "";
      client.on("connect", () => {
        try {
          if (stopped || socket !== client || epoch !== generation) { client.destroy(); return; }
          lastError = "";
          dirty = true;
          flush();
        } catch (error) { report(error); client.destroy(); }
      });
      client.on("data", (chunk: string) => {
        try {
          if (stopped || socket !== client || epoch !== generation) return;
          incoming += chunk;
          if (incoming.length > 256_000) { client.destroy(); return; }
          let end: number;
          while ((end = incoming.indexOf("\n")) !== -1) {
            const message = JSON.parse(incoming.slice(0, end));
            incoming = incoming.slice(end + 1);
            if (record(message)?.type === "ping") {
              client.write('{"type":"pong"}\n');
            } else {
              void command(message, client).catch(report);
            }
          }
        } catch (error) { report(error); client.destroy(); }
      });
      client.on("error", error => {
        if (socket === client) report(error);
        client.destroy();
      });
      client.on("close", () => {
        if (socket !== client) return;
        socket = undefined;
        nextConnect = Date.now() + 5000;
        if (!lastError) lastError = "Companion disconnected; reconnecting";
      });
    } catch (error) { report(error); }
  }

  pi.on("session_start", (_event, context) => {
    // Ordinary task/print subprocesses must not become phone sessions.
    if (!context.hasUI || !process.stdin.isTTY || process.env.OMP_PHONE_DISABLED === "1") return;
    stopped = false;
    generation++;
    updateContext(context);
    context.setInterval(() => {
      if (stopped || !ctx) return;
      if (currentId(ctx) !== sessionId) updateContext(ctx);
      const nextTitle = pi.getSessionName() || basename(ctx.cwd) || "OMP session";
      if (title !== nextTitle) { title = nextTitle; dirty = true; }
      if (socket?.connecting && Date.now() - connectStarted > 10_000) socket.destroy();
      connect();
      flush();
    }, 250);
    connect();
  });
  const sessionChanged = (_event: unknown, context: ExtensionContext): void => {
    if (!stopped) updateContext(context);
  };
  pi.on("session_switch", sessionChanged);
  pi.on("session_branch", sessionChanged);
  pi.on("session_tree", sessionChanged);
  pi.on("session_compact", sessionChanged);
  pi.on("agent_start", (_event, context) => {
    if (stopped) return;
    ctx = context;
    state = "working";
    dirty = true;
    flush();
  });
  pi.on("agent_end", (event, context) => {
    if (stopped) return;
    ctx = context;
    if (!event.willContinue && !context.hasPendingMessages()) state = "idle";
    partial = "";
    dirty = true;
    flush();
  });
  pi.on("message_update", event => {
    if (stopped) return;
    partial = messageText(event.message);
    dirty = true;
  });
  pi.on("message_end", event => {
    if (stopped) return;
    const message = phoneMessage(event.message);
    if (message) { messages.push(message); trimMessages(); }
    if (record(event.message)?.role === "assistant") partial = "";
    dirty = true;
  });
  pi.on("session_shutdown", () => {
    stopped = true;
    generation++;
    socket?.destroy();
    socket = undefined;
    ctx = undefined;
  });
  pi.registerCommand("phone", {
    description: "Show this session's phone connection status",
    handler: async (_args, context) => {
      context.ui.notify(stopped ? "Phone sharing is disabled for this session" : socket?.readyState === "open"
        ? "Phone connected. Run `omp-phone pair` in a shell to obtain your private pairing link."
        : `Phone disconnected: ${lastError}`, socket?.readyState === "open" ? "info" : "warning");
    },
  });
}
