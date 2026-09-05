import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { readFile } from "node:fs/promises";
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
  const port = Number(process.env.OMP_PHONE_PORT ?? "8787");
  let ctx: ExtensionContext | undefined;
  let socket: WebSocket | undefined;
  let connecting = false;
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
    if (!dirty || !ctx || socket?.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > 1_000_000) {
      socket.close(1013, "phone companion is not keeping up");
      return;
    }
    socket.send(JSON.stringify({
      type: "snapshot",
      session: { id: sessionId, title, cwd: ctx.cwd, state, messages, partial },
    }));
    dirty = false;
  }

  function report(error: unknown): void {
    lastError = error instanceof Error ? error.message : String(error);
    // Never log the token or the incoming prompt. Network callbacks are outside
    // OMP's event-handler isolation and must not throw into the host process.
  }

  async function command(raw: unknown, source: WebSocket): Promise<void> {
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
      if (source.readyState === WebSocket.OPEN) source.send(JSON.stringify({ type: "result", requestId, ok: true }));
    } catch (error) {
      if (source.readyState === WebSocket.OPEN) {
        source.send(JSON.stringify({ type: "result", requestId, ok: false, error: error instanceof Error ? error.message : "Command failed" }));
      }
    }
  }

  async function connect(): Promise<void> {
    if (stopped || connecting || socket || Date.now() < nextConnect) return;
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      lastError = "OMP_PHONE_PORT must be between 1 and 65535";
      return;
    }
    const epoch = generation;
    connecting = true;
    nextConnect = Date.now() + 5000;
    try {
      const token = (await readFile(join(stateDir, "token"), "utf8")).trim();
      if (stopped || epoch !== generation) return;
      if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) throw new Error("Invalid companion token file");
      // Bun supports headers on its native WebSocket client; no extra runtime
      // dependency is needed in an installed OMP extension.
      const client = new WebSocket(`ws://127.0.0.1:${port}/extension`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      socket = client;
      connectStarted = Date.now();
      client.addEventListener("open", () => {
        try {
          if (stopped || socket !== client || epoch !== generation) { client.close(); return; }
          lastError = "";
          dirty = true;
          flush();
        } catch (error) { report(error); client.close(); }
      });
      client.addEventListener("message", event => {
        try {
          if (typeof event.data !== "string" || event.data.length > 256_000) return;
          void command(JSON.parse(event.data), client).catch(report);
        } catch (error) { report(error); }
      });
      client.addEventListener("error", () => {
        lastError = "Cannot connect to omp-phone; start the companion service";
        client.close();
      });
      client.addEventListener("close", () => {
        if (socket !== client) return;
        socket = undefined;
        nextConnect = Date.now() + 5000;
        if (!lastError) lastError = "Companion disconnected; reconnecting";
      });
    } catch (error) { report(error); }
    finally { connecting = false; }
  }

  pi.on("session_start", (_event, context) => {
    // Ordinary task/print subprocesses must not become phone sessions.
    if (!context.hasUI || !process.stdin.isTTY || process.env.OMP_PHONE_DISABLED === "1") return;
    stopped = false;
    generation++;
    updateContext(context);
    context.setInterval(async () => {
      if (stopped || !ctx) return;
      if (currentId(ctx) !== sessionId) updateContext(ctx);
      const nextTitle = pi.getSessionName() || basename(ctx.cwd) || "OMP session";
      if (title !== nextTitle) { title = nextTitle; dirty = true; }
      if (socket?.readyState === WebSocket.CONNECTING && Date.now() - connectStarted > 10_000) socket.close();
      await connect();
      flush();
    }, 250);
    void connect().catch(report);
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
    socket?.close(1000, "OMP session closed");
    socket = undefined;
    ctx = undefined;
  });
  pi.registerCommand("phone", {
    description: "Show this session's phone connection status",
    handler: async (_args, context) => {
      context.ui.notify(stopped ? "Phone sharing is disabled for this session" : socket?.readyState === WebSocket.OPEN
        ? "Phone connected. Run `omp-phone pair` in a shell to obtain your private pairing link."
        : `Phone disconnected: ${lastError}`, socket?.readyState === WebSocket.OPEN ? "info" : "warning");
    },
  });
}
