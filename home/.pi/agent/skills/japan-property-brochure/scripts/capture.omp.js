// capture.omp.js: capture one property listing, and its sub-pages, in omp's browser.
//
// Load it in an omp JavaScript eval cell, then call it:
//
//   %load "<skill>/scripts/capture.omp.js"
//   await jpCapture({ skill: "<skill>", dir: "<brochure folder>", url: "<listing URL>" })
//
// It opens the listing, runs JPX.detail() on it and on each sub-page the
// listing links to, and writes the results to <dir>/capture/NN-name.json. It
// reads pages only: it never logs in, submits a form or clicks an inquiry
// button, and it waits three seconds between pages.
//
// Options:
//   skill     the japan-property-brochure skill directory (required)
//   dir       the brochure folder from `brochure new` (required)
//   url       the listing URL (required unless `target` is given)
//   subpages  false to capture only the main page; default true, at most 6
//   app       browser to use, default "own" (omp's own browser)
//   target    borrow a tab the user already has open (URL or title substring,
//             with app "relay"); the tab is read as it stands and is never
//             navigated, so sub-pages are skipped
//
// Returns { pages: [{ file, url, pairs, images, blocked }], skipped: [...] }.

globalThis.jpCapture = async function jpCapture(options = {}) {
  const { skill, dir } = options;
  if (!skill || !dir) throw new Error("jpCapture needs { skill, dir } and a url or target");
  if (!options.url && !options.target) throw new Error("jpCapture needs the listing url, or target to borrow an open tab");
  const jpx = await Bun.file(`${skill}/scripts/jpx.js`).text();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const read = `(async () => { await JPX.settle(20000); await JPX.autoScroll(); return Object.assign(JPX.detail(), { blocked: JPX.blocked() }); })()`;

  const borrowed = Boolean(options.target);
  const tab = borrowed
    ? await browser.open({ name: "jp-listing", app: options.app || "relay", target: options.target })
    : await browser.open({ name: "jp-listing", url: "about:blank", app: options.app || "own", wait_until: "domcontentloaded", timeout: 90 });

  const pages = [];
  const capturePage = async (url, number, name) => {
    if (url) {
      await tab.goto(url, { waitUntil: "domcontentloaded" });
      if ((await tab.evaluate("document.readyState")) === "loading") throw new Error(`page was still loading: ${url}`);
    }
    await tab.evaluate(jpx);
    const detail = await tab.evaluate(read);
    const file = `${String(number).padStart(2, "0")}-${name}.json`;
    await Bun.write(`${dir}/capture/${file}`, JSON.stringify(detail, null, 1));
    pages.push({ file, url: detail.url, pairs: detail.pairs.length, images: detail.images.length, blocked: detail.blocked });
    return detail;
  };

  const skipped = [];
  try {
    const main = await capturePage(borrowed ? null : options.url, 1, "main");
    // The agent's shop page describes the agent, not the property, and its
    // photos are of other listings.
    const aboutAgent = (s) => /店舗|会社|スタッフ|企業/.test(s.text || "");
    const wanted = options.subpages === false || borrowed ? [] : main.subpages.filter((s) => !aboutAgent(s)).slice(0, 6);
    if (borrowed && main.subpages.length) skipped.push(...main.subpages.map((s) => s.url));
    skipped.push(...main.subpages.filter(aboutAgent).map((s) => `${s.url} (agent's shop page)`));
    let number = 2;
    for (const sub of wanted) {
      await sleep(3000);
      const name = (new URL(sub.url).pathname.replace(/\/$/, "").split("/").pop() || "sub").replace(/[^A-Za-z0-9_-]/g, "") || "sub";
      try {
        await capturePage(sub.url, number, name);
        number += 1;
      } catch (error) {
        skipped.push(`${sub.url} (${String((error && error.message) || error).slice(0, 120)})`);
      }
    }
  } finally {
    if (!borrowed) await tab.close().catch(() => {});
  }
  return { pages, skipped };
};
