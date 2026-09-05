"use strict";

// Erase pairing credentials before any application requests or service-worker work.
const initialHash = new URLSearchParams(location.hash.slice(1));
let pairingToken = initialHash.get("token");
if (initialHash.has("token")) history.replaceState(null, "", location.pathname + location.search);
initialHash.delete("token");

const $ = id => document.getElementById(id);
const drafts = new Map();
const commandMessages = new Map();
const pending = new Set();
let sessions = [];
let authenticated = false;
let connected = false;
let events = null;
let generation = 0;
let authGeneration = 0;
let snapshotVersion = 0;
let currentId = null;
let renderedId = null;
let subscription = null;
let pushBusy = false;
let pushReady = false;
let registrationPromise = null;

class RequestError extends Error {
  constructor(message, uncertain = false, status = 0) {
    super(message);
    this.uncertain = uncertain;
    this.status = status;
  }
}

async function api(path, method = "GET", body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    let data;
    try { data = await response.json(); } catch { data = null; }
    if (!response.ok) {
      throw new RequestError(data?.error || `Request failed (${response.status}).`, response.status >= 500 || response.status === 408, response.status);
    }
    return data;
  } catch (error) {
    if (error instanceof RequestError) throw error;
    throw new RequestError(error.name === "AbortError" ? "The request timed out." : "Could not reach your computer.", true);
  } finally {
    clearTimeout(timeout);
  }
}

function routeId() {
  const id = new URLSearchParams(location.hash.slice(1)).get("session");
  return id && /^[A-Za-z0-9_-]+$/.test(id) ? id : null;
}

function activeSession() {
  return sessions.find(session => session.id === currentId);
}

function setConnected(value, message) {
  connected = value && navigator.onLine;
  $("connection").dataset.live = String(connected);
  $("connection").textContent = message || (connected
    ? "Live · connected to your computer"
    : "Disconnected · replies and Stop are unavailable. Reconnecting…");
  updateControls();
}

function updateControls() {
  const session = activeSession();
  const writable = authenticated && connected && Boolean(session);
  const busy = pending.has(currentId);
  $("prompt").disabled = !writable;
  $("send").disabled = !writable || busy || !$("prompt").value.trim();
  $("send").textContent = busy ? "Sending…" : "Send";
  $("stop").disabled = !writable || busy || session.state !== "working";
  $("composer-hint").textContent = !connected
    ? "Disconnected. Your draft stays here."
    : session?.state === "working"
      ? "Replies queue after the current turn. Approvals stay in the terminal."
      : "Questions and approvals stay in the terminal.";
  $("push-button").disabled = !authenticated || !connected || !pushReady || pushBusy;
  $("push-button").textContent = pushBusy ? "Updating…" : subscription ? "Disable notifications" : "Enable notifications";
}

function dateLabel(timestamp) {
  const date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) return { short: "", full: "" };
  const today = new Date().toDateString() === date.toDateString();
  return {
    short: date.toLocaleString(undefined, today ? { hour: "numeric", minute: "2-digit" } : { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }),
    full: date.toLocaleString(),
  };
}

function sessionRow(session) {
  const row = document.createElement("a");
  row.className = "session-row";
  row.href = `#session=${encodeURIComponent(session.id)}`;
  const title = document.createElement("div");
  title.className = "row-title";
  title.textContent = session.title || "Untitled session";
  const meta = document.createElement("div");
  meta.className = "row-meta";
  const cwd = document.createElement("span");
  cwd.className = "row-cwd";
  cwd.textContent = session.cwd;
  cwd.title = session.cwd;
  const time = document.createElement("time");
  time.className = "row-time";
  const label = dateLabel(session.changedAt);
  time.textContent = label.short;
  time.title = `State changed: ${label.full}`;
  time.setAttribute("aria-label", `State changed ${label.full}`);
  if (label.full) time.dateTime = new Date(session.changedAt).toISOString();
  meta.append(cwd, time);
  row.append(title, meta);
  return row;
}

function renderList() {
  const ordered = [...sessions].sort((a, b) => b.changedAt - a.changedAt);
  for (const state of ["idle", "working"]) {
    const container = $(state === "idle" ? "idle-sessions" : "working-sessions");
    const grouped = ordered.filter(session => session.state === state);
    // Reuse links so live transcript updates do not move keyboard focus.
    const existing = new Map([...container.children].map(row => [row.dataset.id, row]));
    for (let index = 0; index < grouped.length; index++) {
      const session = grouped[index];
      let row = existing.get(session.id);
      const signature = JSON.stringify([session.title, session.cwd, session.changedAt]);
      if (!row) { row = sessionRow(session); row.dataset.id = session.id; }
      else if (row.dataset.signature !== signature) {
        const replacement = sessionRow(session);
        row.replaceChildren(...replacement.childNodes);
      }
      row.dataset.signature = signature;
      existing.delete(session.id);
      if (container.children[index] !== row) container.insertBefore(row, container.children[index] || null);
    }
    for (const row of existing.values()) row.remove();
    if (!grouped.length) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = state === "idle" ? "No sessions waiting for you." : "Nothing working right now.";
      container.append(empty);
    }
  }
  $("session-count").textContent = `${sessions.length} live`;
}

function messageNode(message) {
  const tool = message.role === "tool";
  const node = document.createElement(tool ? "details" : "article");
  node.className = `message ${tool ? "tool" : message.role === "user" ? "user" : "assistant"}`;
  node.dataset.role = message.role;
  const label = document.createElement(tool ? "summary" : "h2");
  label.textContent = tool ? "Tool activity · expand output" : message.role === "user" ? "You" : "Assistant";
  const text = document.createElement("div");
  text.className = "message-text";
  text.textContent = message.text;
  node.append(label, text);
  return node;
}

function renderTranscript() {
  const session = activeSession();
  const scroller = $("transcript");
  const changedSession = renderedId !== currentId;
  const previousTop = scroller.scrollTop;
  const atBottom = scroller.scrollHeight - previousTop - scroller.clientHeight < 80;
  if (changedSession) {
    $("messages").replaceChildren();
    renderedId = currentId;
  }
  $("session-title").textContent = session?.title || (session ? "Untitled session" : "Session unavailable");
  $("session-cwd").textContent = session?.cwd || "";
  $("session-cwd").title = session?.cwd || "";
  $("session-state").textContent = session ? session.state === "idle" ? "Your turn" : "Working" : "Offline";
  $("session-missing").hidden = Boolean(session);
  const messages = session?.messages || [];
  const container = $("messages");
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    const existing = container.children[index];
    if (!existing) container.append(messageNode(message));
    else if (existing.dataset.role !== message.role) existing.replaceWith(messageNode(message));
    else if (existing.lastElementChild.textContent !== message.text) existing.lastElementChild.textContent = message.text;
  }
  while (container.children.length > messages.length) container.lastElementChild.remove();
  const partial = session?.partial || "";
  if ($("partial-text").textContent !== partial) $("partial-text").textContent = partial;
  $("partial-message").hidden = !partial;
  $("transcript-empty").hidden = !session || messages.length > 0 || Boolean(partial);
  scroller.scrollTop = changedSession || atBottom ? scroller.scrollHeight : previousTop;
}

function renderRoute() {
  const nextId = routeId();
  if (nextId !== currentId) {
    if (currentId) drafts.set(currentId, $("prompt").value);
    currentId = nextId;
    $("prompt").value = drafts.get(currentId) || "";
  }
  $("login-view").hidden = authenticated;
  $("sessions-view").hidden = !authenticated || Boolean(currentId);
  $("session-view").hidden = !authenticated || !currentId;
  $("logout").hidden = !authenticated;
  if (authenticated && currentId) renderTranscript();
  if (authenticated && !currentId) renderList();
  $("command-status").textContent = commandMessages.get(currentId) || "";
  updateControls();
}

function applySnapshot(data) {
  if (!data || !Array.isArray(data.sessions)) throw new Error("Invalid session snapshot.");
  sessions = data.sessions;
  $("machine").textContent = data.hostname || "Your computer";
  renderRoute();
}

function closeEvents() {
  generation++;
  if (events) events.close();
  events = null;
}

function showLogin(message = "") {
  authGeneration++;
  closeEvents();
  authenticated = false;
  sessions = [];
  drafts.clear();
  commandMessages.clear();
  pending.clear();
  $("prompt").value = "";
  $("messages").replaceChildren();
  $("partial-text").textContent = "";
  $("idle-sessions").replaceChildren();
  $("working-sessions").replaceChildren();
  renderedId = null;
  $("machine").textContent = "Your local companion";
  $("login-error").textContent = message;
  setConnected(false, navigator.onLine ? "Pair with your computer to connect." : "Offline · connect to your network to pair.");
  renderRoute();
}

function openEvents() {
  closeEvents();
  const ownGeneration = generation;
  let checkingLogin = false;
  const source = new EventSource("/api/events", { withCredentials: true });
  events = source;
  source.addEventListener("open", async () => {
    const version = snapshotVersion;
    try {
      // Always refresh on reconnect; SSE events are complete snapshots, not a replay log.
      const data = await api("/api/sessions");
      if (generation !== ownGeneration) return;
      if (version === snapshotVersion) applySnapshot(data);
      if (source.readyState === EventSource.OPEN) setConnected(true);
    } catch (error) {
      if (generation !== ownGeneration) return;
      if (error.status === 401) showLogin("Please pair again.");
      else setConnected(false);
    }
  });
  source.addEventListener("sessions", event => {
    if (generation !== ownGeneration) return;
    try {
      applySnapshot(JSON.parse(event.data));
      snapshotVersion++;
      setConnected(true);
    } catch {
      setConnected(false, "Could not read live sessions. Reload to reconnect.");
    }
  });
  source.addEventListener("error", async () => {
    if (generation !== ownGeneration) return;
    setConnected(false);
    if (checkingLogin) return;
    checkingLogin = true;
    try {
      await api("/api/sessions");
    } catch (error) {
      if (generation === ownGeneration && error.status === 401) showLogin("Please pair again.");
    } finally {
      checkingLogin = false;
    }
  });
}

async function loadSessions() {
  const ownGeneration = authGeneration;
  try {
    const data = await api("/api/sessions");
    if (authGeneration !== ownGeneration) return;
    authenticated = true;
    applySnapshot(data);
    setConnected(false, "Connecting to live updates…");
    openEvents();
    await refreshPush();
  } catch (error) {
    if (authGeneration === ownGeneration) showLogin(error.status === 401 ? "" : error.message);
  }
}

async function login(token) {
  const ownGeneration = ++authGeneration;
  $("login-button").disabled = true;
  $("login-error").textContent = "";
  try {
    await api("/api/login", "POST", { token });
    if (authGeneration !== ownGeneration) return;
    $("token").value = "";
    await loadSessions();
  } catch (error) {
    if (authGeneration === ownGeneration) showLogin(error.message);
  } finally {
    $("login-button").disabled = false;
  }
}

async function command(action) {
  const session = activeSession();
  const id = currentId;
  const text = $("prompt").value;
  if (!authenticated || !connected || !session || pending.has(id) || (action === "prompt" && !text.trim())) return;
  const ownGeneration = authGeneration;
  pending.add(id);
  commandMessages.set(id, action === "prompt" ? "Sending to your session…" : "Requesting stop…");
  renderRoute();
  try {
    const result = await api(`/api/sessions/${encodeURIComponent(id)}/${action}`, "POST", action === "prompt" ? { text } : {});
    if (authGeneration !== ownGeneration) return;
    if (result?.ok !== true) throw new RequestError(result?.error || "The session did not acknowledge the request.", true);
    if (action === "prompt") {
      if (drafts.get(id) === text) drafts.delete(id);
      if (currentId === id && $("prompt").value === text) { $("prompt").value = ""; drafts.delete(id); }
    }
    commandMessages.set(id, action === "prompt" ? "Reply accepted by your session." : "Stop accepted by your session.");
  } catch (error) {
    if (authGeneration !== ownGeneration) return;
    commandMessages.set(id, error.uncertain
      ? `${error.message} Delivery uncertain: check the transcript or terminal before trying again. Nothing will be retried automatically.`
      : error.message);
    if (error.status === 401) { showLogin("Please pair again."); return; }
  } finally {
    if (authGeneration === ownGeneration) { pending.delete(id); renderRoute(); }
  }
}

function pushSupport() {
  if (!window.isSecureContext) return "Notifications require a secure HTTPS address.";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return "Push is unavailable here. On iPhone or iPad, use the installed Home Screen app.";
  return "";
}

async function registration() {
  if (!registrationPromise) registrationPromise = navigator.serviceWorker.register("/sw.js", { scope: "/" }).then(() => navigator.serviceWorker.ready).catch(error => { registrationPromise = null; throw error; });
  return registrationPromise;
}

async function refreshPush() {
  const unsupported = pushSupport();
  if (unsupported) { $("push-status").textContent = unsupported; return; }
  try {
    const worker = await registration();
    subscription = await worker.pushManager.getSubscription();
    pushReady = true;
    $("push-status").textContent = subscription
      ? "This browser has a push subscription. Disable here before signing out if you no longer want notifications. After restoring companion state, disable and enable again."
      : Notification.permission === "denied" ? "Notifications are blocked. Allow them in browser or device settings, then try again." : "Notifications are off on this device.";
  } catch {
    $("push-status").textContent = "Could not initialize notifications. Reload to try again.";
  }
  updateControls();
}

function decodeKey(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded + "=".repeat((4 - padded.length % 4) % 4)), char => char.charCodeAt(0));
}

async function togglePush() {
  if (pushBusy || !connected || !pushReady) return;
  pushBusy = true;
  updateControls();
  try {
    if (subscription) {
      await api("/api/push/subscriptions", "DELETE", { endpoint: subscription.endpoint });
      const removed = await subscription.unsubscribe();
      if (!removed) throw new Error("The server subscription was removed, but this browser could not unsubscribe. Try disabling again.");
      subscription = null;
      $("push-status").textContent = "Notifications disabled on this device.";
    } else {
      // Ask during the user gesture, before unrelated network requests.
      const permission = await Notification.requestPermission();
      if (permission !== "granted") throw new Error(permission === "denied" ? "Notifications are blocked. Allow them in browser or device settings." : "Permission was not granted. Notifications remain off.");
      const key = await api("/api/push/key");
      const worker = await registration();
      const next = await worker.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decodeKey(key.publicKey) });
      try {
        await api("/api/push/subscriptions", "POST", next.toJSON());
        subscription = next;
      } catch (error) {
        // Do not leave a browser-only subscription that looks successfully enabled.
        try { if (!(await next.unsubscribe())) subscription = next; } catch { subscription = next; }
        throw error;
      }
      $("push-status").textContent = "Notifications enabled on this device.";
    }
  } catch (error) {
    $("push-status").textContent = error.uncertain ? `${error.message} The notification setting may not have reached your computer. No automatic retry was made.` : error.message;
  } finally {
    pushBusy = false;
    updateControls();
  }
}

$("login-form").addEventListener("submit", event => { event.preventDefault(); const token = $("token").value.trim(); if (token) void login(token); });
$("composer").addEventListener("submit", event => { event.preventDefault(); void command("prompt"); });
$("stop").addEventListener("click", () => { void command("abort"); });
$("prompt").addEventListener("input", () => { if (currentId) drafts.set(currentId, $("prompt").value); updateControls(); });
$("push-button").addEventListener("click", () => { void togglePush(); });
$("logout").addEventListener("click", async () => {
  $("logout").disabled = true;
  try { await api("/api/logout", "POST", {}); showLogin(); }
  catch (error) { setConnected(false, `Sign out could not be confirmed. ${error.message}`); }
  finally { $("logout").disabled = false; }
});
window.addEventListener("hashchange", () => {
  const hash = new URLSearchParams(location.hash.slice(1));
  if (hash.has("token")) {
    const token = hash.get("token");
    history.replaceState(null, "", location.pathname + location.search);
    showLogin();
    if (token) void login(token);
  } else renderRoute();
});
window.addEventListener("offline", () => setConnected(false, "Offline · replies and Stop are unavailable. Your draft stays here."));
window.addEventListener("online", () => { if (authenticated) { setConnected(false); openEvents(); } else setConnected(false, "Pair with your computer to connect."); });
window.addEventListener("pageshow", event => { if (event.persisted && authenticated) { setConnected(false); openEvents(); } });
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && authenticated) { setConnected(false); openEvents(); }
});
showLogin();
if (pairingToken) void login(pairingToken);
else void loadSessions();
pairingToken = null;
