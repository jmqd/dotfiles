// ==UserScript==
// @name         Agent Feedback
// @namespace    jmq.agent-feedback
// @version      1.0.0
// @description  Alt/Option+right-click any element to leave a note. Copy this site's notes as JSON for a coding agent.
// @match        *://*/*
// @match        file:///*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_setClipboard
// @grant        GM_registerMenuCommand
// @run-at       document-idle
// @noframes
// ==/UserScript==
//
// Install: add to Tampermonkey/Violentmonkey, or paste into the DevTools console
// for a one-off session. Under a userscript manager, notes live in extension
// storage keyed by origin, so a site clearing its own localStorage cannot erase
// them. Without one, notes fall back to the page's localStorage.
//
// Use: Alt/Option+right-click an element, type, press Enter. Plain right-click
// keeps the native menu. "Copy & clear" in the corner badge copies every note
// for this origin and clears them only after the clipboard write succeeds.

(() => {
  "use strict";
  if (globalThis.__agentFeedbackInstalled) return;
  globalThis.__agentFeedbackInstalled = true;

  const FORMAT = "agent-feedback/v1";
  const SITE = location.origin !== "null" ? location.origin : location.href.split(/[?#]/)[0];
  const STORE_KEY = `agent-feedback:v1:${SITE}`;
  const hasGM = typeof GM_getValue === "function" && typeof GM_setValue === "function";

  // Corrupt storage throws instead of reading as empty, so a later save cannot
  // overwrite notes we failed to parse.
  const load = () => JSON.parse((hasGM ? GM_getValue(STORE_KEY) : localStorage.getItem(STORE_KEY)) || "[]");
  const save = (notes) => {
    const raw = JSON.stringify(notes);
    hasGM ? GM_setValue(STORE_KEY, raw) : localStorage.setItem(STORE_KEY, raw);
    render();
  };

  const clip = (value, max) => {
    const text = (value ?? "").replace(/\s+/g, " ").trim();
    if (!text) return undefined;
    return text.length > max ? `${text.slice(0, max - 1)}…` : text;
  };

  const esc = (value) => CSS.escape(value);

  const segment = (el) => {
    const tag = el.tagName.toLowerCase();
    if (el.id) return `${tag}#${esc(el.id)}`;
    const classes = [...el.classList].slice(0, 2).map((c) => `.${esc(c)}`).join("");
    const siblings = el.parentElement
      ? [...el.parentElement.children].filter((c) => c.tagName === el.tagName)
      : [];
    return siblings.length > 1
      ? `${tag}${classes}:nth-of-type(${siblings.indexOf(el) + 1})`
      : `${tag}${classes}`;
  };

  const selector = (el) => {
    const parts = [];
    for (let cur = el; cur && cur !== document.documentElement && parts.length < 8; cur = cur.parentElement) {
      parts.unshift(segment(cur));
      if (cur.id) break;
    }
    return parts.join(" > ");
  };

  const describe = (el) => {
    const r = el.getBoundingClientRect();
    return {
      selector: selector(el),
      tag: el.tagName.toLowerCase(),
      classes: [...el.classList],
      attributes: Object.fromEntries(
        [...el.attributes]
          .filter((a) => a.name !== "class" && a.name !== "style")
          .map((a) => [a.name, clip(a.value, 200) ?? ""]),
      ),
      text: clip(el.innerText ?? el.textContent, 300),
      outer_html: clip(el.outerHTML, 1500),
      rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) },
    };
  };

  const browserContext = () => ({
    user_agent: navigator.userAgent,
    platform: navigator.userAgentData?.platform ?? navigator.platform,
    language: navigator.language,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    viewport: { width: innerWidth, height: innerHeight },
    screen: { width: screen.width, height: screen.height },
    device_pixel_ratio: devicePixelRatio,
    scroll: { x: Math.round(scrollX), y: Math.round(scrollY) },
    color_scheme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
  });

  const exportJson = (notes) =>
    JSON.stringify({ format: FORMAT, site: SITE, exported_at: new Date().toISOString(), count: notes.length, notes }, null, 2);

  const copyText = async (text) => {
    if (typeof GM_setClipboard === "function") return GM_setClipboard(text, "text");
    if (navigator.clipboard && isSecureContext) return navigator.clipboard.writeText(text);
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.documentElement.append(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    if (!ok) throw new Error("clipboard write blocked");
  };

  // --- UI (shadow DOM keeps page CSS out; adoptedStyleSheets is not blocked by CSP) ---
  const host = document.createElement("div");
  host.setAttribute("data-agent-feedback", "");
  const root = host.attachShadow({ mode: "open" });
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`
    :host { all: initial; }
    * { box-sizing: border-box; font: 13px/1.4 system-ui, sans-serif; }
    .panel, .badge { position: fixed; z-index: 2147483647; background: #1e1e1e; color: #eee;
      border: 1px solid #555; border-radius: 8px; box-shadow: 0 6px 24px #0007; }
    .panel { width: 340px; padding: 10px; display: none; }
    .panel.open { display: block; }
    .target { color: #aaa; font-family: ui-monospace, monospace; font-size: 11px; margin: 0 0 6px;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    textarea { width: 100%; min-height: 90px; resize: vertical; background: #111; color: #eee;
      border: 1px solid #555; border-radius: 6px; padding: 6px; }
    .row { display: flex; gap: 6px; justify-content: flex-end; align-items: center; margin-top: 6px; }
    .hint { color: #888; font-size: 11px; margin-right: auto; }
    button { background: #333; color: #eee; border: 1px solid #666; border-radius: 6px; padding: 4px 10px; cursor: pointer; }
    button.primary { background: #2f6fde; border-color: #2f6fde; }
    .badge { right: 12px; bottom: 12px; padding: 6px 8px; display: none; gap: 6px; align-items: center; }
    .badge.show { display: flex; }
    .toast { color: #9c9; font-size: 11px; }
  `);
  root.adoptedStyleSheets = [sheet];
  root.innerHTML = `
    <div class="panel" part="panel">
      <p class="target"></p>
      <textarea placeholder="What should change here?"></textarea>
      <div class="row"><span class="hint">Enter saves · Shift+Enter newline · Esc cancels</span>
        <button class="cancel">Cancel</button><button class="primary save">Save</button></div>
    </div>
    <div class="badge"><span class="count"></span><span class="toast"></span>
      <button class="copy">Copy</button><button class="primary copy-clear">Copy &amp; clear</button></div>`;
  document.documentElement.append(host);

  const $ = (sel) => root.querySelector(sel);
  const panel = $(".panel");
  const textarea = $("textarea");
  const badge = $(".badge");
  const toast = $(".toast");
  let pending = null;
  let toastTimer;

  // The badge stays visible while a toast shows, so "cleared" and error
  // messages remain readable after the count drops to zero.
  const flash = (message) => {
    toast.textContent = message;
    badge.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast.textContent = "";
      render();
    }, 2500);
  };

  function render() {
    const n = load().length;
    $(".count").textContent = `${n} note${n === 1 ? "" : "s"}`;
    badge.classList.toggle("show", n > 0 || toast.textContent !== "");
  }

  const close = () => {
    panel.classList.remove("open");
    pending = null;
  };

  const submit = () => {
    const feedback = textarea.value.trim();
    if (!feedback || !pending) return;
    const notes = load();
    notes.push({ feedback, ...pending });
    save(notes);
    textarea.value = "";
    close();
    flash("saved");
  };

  const copy = async ({ clear }) => {
    const notes = load();
    if (!notes.length) return flash("nothing to copy");
    await copyText(exportJson(notes));
    // Re-read and drop only exported ids: a note saved from another tab while
    // the clipboard write was pending must survive.
    if (clear) {
      const copied = new Set(notes.map((n) => n.id));
      save(load().filter((n) => !copied.has(n.id)));
    }
    flash(clear ? `copied ${notes.length}, cleared` : `copied ${notes.length}`);
  };

  const guarded = (fn) => (...args) =>
    Promise.resolve()
      .then(() => fn(...args))
      .catch((err) => {
        flash(`error: ${err.message}`);
        console.error("[agent-feedback]", err);
      });

  $(".save").addEventListener("click", guarded(submit));
  $(".cancel").addEventListener("click", close);
  $(".copy").addEventListener("click", guarded(() => copy({ clear: false })));
  $(".copy-clear").addEventListener("click", guarded(() => copy({ clear: true })));

  // Keys typed in the panel must not reach page hotkey handlers, which see the
  // retargeted shadow host rather than our textarea.
  for (const type of ["keydown", "keyup", "keypress"]) {
    panel.addEventListener(type, (e) => e.stopPropagation());
  }
  textarea.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
    else if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      guarded(submit)();
    }
  });

  document.addEventListener(
    "contextmenu",
    (e) => {
      if (!e.altKey) return;
      const path = e.composedPath();
      if (path.includes(host)) return;
      const target = path.find((n) => n instanceof Element);
      if (!target) return;
      e.preventDefault();
      e.stopPropagation();

      pending = {
        id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
        created_at: new Date().toISOString(),
        url: location.href,
        title: document.title,
        referrer: document.referrer || undefined,
        selection: clip(getSelection()?.toString(), 1000),
        click: { x: Math.round(e.clientX), y: Math.round(e.clientY), page_x: Math.round(e.pageX), page_y: Math.round(e.pageY) },
        element: describe(target),
        browser: browserContext(),
      };

      $(".target").textContent = pending.element.selector;
      $(".target").title = pending.element.selector;
      panel.classList.add("open");
      panel.style.left = `${Math.min(Math.max(8, e.clientX + 12), innerWidth - 348)}px`;
      panel.style.top = `${Math.min(Math.max(8, e.clientY + 12), innerHeight - panel.offsetHeight - 8)}px`;
      textarea.focus({ preventScroll: true });
    },
    true,
  );

  if (typeof GM_registerMenuCommand === "function") {
    GM_registerMenuCommand("Copy & clear notes for this site", guarded(() => copy({ clear: true })));
    GM_registerMenuCommand("Copy notes for this site", guarded(() => copy({ clear: false })));
  }

  guarded(render)();
})();
