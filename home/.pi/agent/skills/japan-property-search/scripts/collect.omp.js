// collect.omp.js: run a jpsearch plan in omp's browser.
//
// Load it in an omp JavaScript eval cell, then call it:
//
//   %load "<skill>/scripts/collect.omp.js"
//   await jpCollect({ skill: "<skill>" })
//
// It repeats `jpsearch plan`, fetches every task the plan marks `todo`, and
// finishes with `jpsearch build`. It decides nothing itself: which URLs may be
// fetched (robots.txt), when to stop paging, which detail pages are worth
// reading and whether a failed page is tried again are all the planner's
// decisions, re-made after every round.
//
// It writes capture files under the workspace and reads the sites named in
// the plan. It never logs in and never submits forms. A site that fails or
// shows a block page three times in a row is left alone for the rest of the
// call; its unfetched pages stay `todo`, so calling jpCollect again resumes.
//
// Options:
//   skill        the skill directory (required)
//   home, run    workspace and run name, as for jpsearch
//   retryFailed  true: also fetch again the pages whose load failed for good earlier
//   app          browser to use (default "own")
//   maxRounds    plan/fetch rounds before giving up (default 40)
//   log          function for progress lines (default console.log)
//
// Returns { loaded, finished, left, summary }: pages loaded in this call,
// whether nothing is left to fetch, the hosts given up on, and what
// `jpsearch build` printed.

globalThis.jpCollect = async function jpCollect(options = {}) {
  const skill = options.skill;
  if (!skill) throw new Error("jpCollect needs { skill: '<path to the japan-property-search skill>' }");
  const log = options.log || ((line) => console.log(line));
  const quote = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";
  const scope = (options.home ? ` --home ${quote(options.home)}` : "") + (options.run ? ` --run ${quote(options.run)}` : "");
  const jpsearch = (command) => sh(`python3 ${quote(skill + "/scripts/jpsearch")} ${command}${scope}`);
  const jpx = await Bun.file(`${skill}/scripts/jpx.js`).text();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const inPage = {
    robots: () =>
      `(async () => { const r = await fetch(location.href, { cache: "no-store" }); return { status: r.status, text: (await r.text()).slice(0, 500000) }; })()`,
    links: (x) => `(async () => { await JPX.settle(); return { blocked: JPX.blocked(), links: JPX.links(${JSON.stringify(x.pattern)}) }; })()`,
    inputs: (x) => `(async () => { await JPX.settle(); return { blocked: JPX.blocked(), inputs: JPX.values(${JSON.stringify(x.selector)}) }; })()`,
    list: (x) =>
      `(async () => { await JPX.settle(); return { blocked: JPX.blocked(), info: JPX.pageInfo(${JSON.stringify({ hits: x.hits, next: x.next })}), cards: JPX.cards(${JSON.stringify({ selector: x.card, link: x.link })}) }; })()`,
    detail: () =>
      `(async () => { await JPX.settle(); await JPX.autoScroll(); return Object.assign(JPX.detail(), { blocked: JPX.blocked() }); })()`,
  };

  const withTimeout = (promise, ms, what) =>
    Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} took longer than ${ms / 1000} s`)), ms))]);

  // One tab per host. A tab is thrown away after any failure: a navigation
  // that timed out is still running inside it, and every later call on that
  // tab would fail as "busy".
  const tabs = new Map();
  let opened = 0;
  const tabFor = async (host) => {
    if (!tabs.has(host)) {
      opened += 1;
      tabs.set(host, await browser.open({ name: `jp-${host}-${opened}`, url: "about:blank", app: options.app || "own", timeout: 60 }));
    }
    return tabs.get(host);
  };
  const dropTab = async (host) => {
    const tab = tabs.get(host);
    tabs.delete(host);
    if (tab) await tab.close().catch(() => {});
  };

  // A page is read only after its HTML has been parsed to the end. Large
  // result pages arrive slowly, and a navigation cut short leaves a DOM
  // holding only the first cards, which would read as a short list.
  //
  // The HTTP status is recorded too. A server error page (a 502 from a CDN)
  // is a failed load to try again, not an empty result. 404 and 410 are left
  // for the planner to interpret: for a listing they mean it was withdrawn.
  const capture = async (host, task) => {
    const envelope = { task, attempt: task.attempt || 1, fetched_at: new Date().toISOString(), final_url: null, http_status: null, error: null, result: null };
    try {
      const fn = task.extract.fn;
      if (!inPage[fn]) throw new Error(`plan asks for unknown extraction '${fn}'`);
      const tab = await tabFor(host);
      await withTimeout(tab.goto(task.url, { waitUntil: "domcontentloaded" }), 90000, "page load");
      if ((await tab.evaluate("document.readyState")) === "loading") throw new Error("page was still loading after navigation returned");
      envelope.final_url = await tab.url();
      envelope.http_status = (await tab.evaluate("(performance.getEntriesByType('navigation')[0] || {}).responseStatus || 0")) || null;
      const status = envelope.http_status || 200;
      if (fn !== "robots" && status >= 400 && status !== 404 && status !== 410) throw new Error(`the site answered HTTP ${status}`);
      if (fn !== "robots") await tab.evaluate(jpx);
      envelope.result = await withTimeout(tab.evaluate(inPage[fn](task.extract)), 90000, "reading the page");
    } catch (error) {
      envelope.error = String((error && error.message) || error).split("\n")[0].slice(0, 300);
      await dropTab(host);
    }
    return envelope;
  };

  const yieldedNothing = (envelope) => {
    if (envelope.error) return true;
    if (envelope.task.kind === "robots") return false;
    const r = envelope.result || {};
    const got = (r.cards || []).length + (r.links || []).length + (r.inputs || []).length + (r.pairs || []).length;
    return got === 0 && (r.blocked || []).length > 0;
  };

  const left = new Set();
  let loaded = 0;
  const runHost = async (home, host, tasks) => {
    let strikes = 0;
    let done = 0;
    for (const task of tasks) {
      const envelope = await capture(host, task);
      await Bun.write(`${home}/${task.out}`, JSON.stringify(envelope));
      loaded += 1;
      done += 1;
      strikes = yieldedNothing(envelope) ? strikes + 1 : 0;
      if (strikes >= 3) {
        left.add(host);
        log(`  ${host}: three pages in a row failed or were block pages; leaving this site (${tasks.length - done} pages unfetched)`);
        break;
      }
      if (done % 25 === 0) log(`  ${host}: ${done}/${tasks.length}`);
      await sleep(task.delay_seconds * 1000 + Math.random() * 800);
    }
    await dropTab(host);
  };

  const maxRounds = options.maxRounds || 40;
  let finished = false;
  for (let round = 1; round <= maxRounds; round++) {
    const output = await jpsearch(round === 1 && options.retryFailed ? "plan --retry-failed" : "plan");
    const planPath = (output.match(/^plan: (.+)$/m) || [])[1];
    if (!planPath) throw new Error("jpsearch plan did not report a plan file:\n" + output);
    const plan = JSON.parse(await Bun.file(planPath.trim()).text());
    const pending = plan.tasks.filter((t) => t.status === "todo");
    const todo = pending.filter((t) => !left.has(t.host));
    if (todo.length === 0) {
      finished = pending.length === 0;
      break;
    }
    const byHost = new Map();
    for (const task of todo) {
      if (!byHost.has(task.host)) byHost.set(task.host, []);
      byHost.get(task.host).push(task);
    }
    log(`round ${round}: ${todo.length} pages on ${byHost.size} host(s)`);
    await Promise.all([...byHost].map(([host, tasks]) => runHost(plan.home, host, tasks)));
  }
  if (!finished) log("pages are still unfetched; call jpCollect again to continue");
  const summary = await jpsearch("build");
  log(summary);
  return { loaded, finished, left: [...left], summary };
};
