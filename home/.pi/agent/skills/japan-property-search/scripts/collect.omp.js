// collect.omp.js: run a jpsearch plan in omp's browser.
//
// Load it in an omp JavaScript eval cell, then call it:
//
//   %load "<skill>/scripts/collect.omp.js"
//   await jpCollect({ skill: "<skill>" })
//
// It repeats `jpsearch plan`, fetches every task the plan marks `todo`, and
// finishes with `jpsearch build`. It decides nothing itself: which URLs may be
// fetched (robots.txt), when to stop paging and which detail pages are worth
// reading are all the planner's decisions, re-made after every round.
//
// It writes capture files under the workspace and reads the sites named in
// the plan. It never logs in, never submits forms, and stops using a host
// that answers with errors or block pages three times in a row.
//
// Options: skill (required, the skill directory), home, run, app (browser to
// use, default "own"), maxRounds (default 40), log (function, default print).

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
    list: (x) =>
      `(async () => { await JPX.settle(); return { blocked: JPX.blocked(), info: JPX.pageInfo(${JSON.stringify({ hits: x.hits, next: x.next })}), cards: JPX.cards(${JSON.stringify({ selector: x.card, link: x.link })}) }; })()`,
    detail: () =>
      `(async () => { await JPX.settle(); await JPX.autoScroll(); return Object.assign(JPX.detail(), { blocked: JPX.blocked() }); })()`,
  };

  const withTimeout = (promise, ms, what) =>
    Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} took longer than ${ms / 1000} s`)), ms))]);

  // Large result pages arrive slowly, and a navigation that is cut short
  // leaves a DOM holding only the first cards. So a page is read only after
  // its HTML has been parsed to the end; a load that fails is retried once
  // and otherwise recorded as an error, never read as it stands.
  const load = async (tab, url) => {
    let failure;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await withTimeout(tab.goto(url, { waitUntil: "domcontentloaded" }), 90000, "page load");
        if ((await tab.evaluate("document.readyState")) !== "loading") return;
        failure = new Error("page was still loading after navigation returned");
      } catch (error) {
        failure = error;
      }
      await sleep(3000);
    }
    throw failure;
  };

  const capture = async (tab, task) => {
    const envelope = { task, fetched_at: new Date().toISOString(), final_url: null, error: null, result: null };
    try {
      const fn = task.extract.fn;
      if (!inPage[fn]) throw new Error(`plan asks for unknown extraction '${fn}'`);
      await load(tab, task.url);
      envelope.final_url = await tab.url();
      if (fn !== "robots") await tab.evaluate(jpx);
      envelope.result = await withTimeout(tab.evaluate(inPage[fn](task.extract)), 90000, "reading the page");
    } catch (error) {
      envelope.error = String((error && error.message) || error).slice(0, 500);
    }
    return envelope;
  };

  const yieldedNothing = (envelope) => {
    if (envelope.error) return true;
    const r = envelope.result || {};
    if (envelope.task.kind === "robots") return false;
    const got = (r.cards || []).length + (r.links || []).length + (r.pairs || []).length;
    return got === 0 && (r.blocked || []).length > 0;
  };

  const runHost = async (home, host, tasks) => {
    const tab = await browser.open({
      name: "jp-" + host,
      url: "about:blank",
      app: options.app || "own",
      wait_until: "domcontentloaded",
      timeout: 60,
    });
    let strikes = 0;
    let done = 0;
    try {
      for (const task of tasks) {
        let envelope;
        if (strikes >= 3) {
          envelope = { task, fetched_at: new Date().toISOString(), final_url: null, result: null,
            error: "not fetched: this host answered with errors or block pages three times in a row" };
        } else {
          envelope = await capture(tab, task);
          strikes = yieldedNothing(envelope) ? strikes + 1 : 0;
          await sleep(task.delay_seconds * 1000 + Math.random() * 800);
        }
        await Bun.write(`${home}/${task.out}`, JSON.stringify(envelope));
        done += 1;
        if (done % 25 === 0) log(`  ${host}: ${done}/${tasks.length}`);
      }
    } finally {
      await tab.close().catch(() => {});
    }
    if (strikes >= 3) log(`  ${host}: stopped after repeated errors or block pages`);
  };

  const maxRounds = options.maxRounds || 40;
  let fetched = 0;
  let finished = false;
  for (let round = 1; round <= maxRounds; round++) {
    const output = await jpsearch("plan");
    const planPath = (output.match(/^plan: (.+)$/m) || [])[1];
    if (!planPath) throw new Error("jpsearch plan did not report a plan file:\n" + output);
    const plan = JSON.parse(await Bun.file(planPath.trim()).text());
    const todo = plan.tasks.filter((t) => t.status === "todo");
    if (todo.length === 0) {
      finished = true;
      break;
    }
    const byHost = new Map();
    for (const task of todo) {
      if (!byHost.has(task.host)) byHost.set(task.host, []);
      byHost.get(task.host).push(task);
    }
    log(`round ${round}: ${todo.length} pages on ${byHost.size} host(s)`);
    await Promise.all([...byHost].map(([host, tasks]) => runHost(plan.home, host, tasks)));
    fetched += todo.length;
  }
  if (!finished) log(`stopped after ${maxRounds} rounds with pages still to fetch; call jpCollect again to continue`);
  const summary = await jpsearch("build");
  log(summary);
  return { fetched, finished, summary };
};
