// jpx.js: in-page extractor for Japanese real-estate sites.
//
// Evaluate this file in a listing page (search results or one property).
// It defines window.JPX and changes nothing on the page. It reads the DOM by
// the Japanese labels the industry uses (価格, 土地面積, 建物面積, ...) rather
// than by site-specific class names, so it keeps working when a site restyles
// and it works on agency sites nobody wrote an adapter for.
//
// JPX returns raw text only. All interpretation (numbers, units, dates,
// criteria) happens in the Python tools, so there is one place to fix parsing.
//
// This file is vendored byte-for-byte in japan-property-search and
// japan-property-brochure; tests/japan-property-skills.sh fails if they differ.
(() => {
  "use strict";

  const VERSION = "1.0.0";

  // ---------------------------------------------------------------- text

  const clean = (s) =>
    (s == null ? "" : String(s))
      .replace(/[\u00a0\u3000\u200b]/g, " ")
      .replace(/[ \t\r\f\v]+/g, " ")
      .replace(/ *\n */g, "\n")
      .replace(/\n{2,}/g, "\n")
      .trim();

  const textOf = (el) => clean(el ? el.innerText || el.textContent : "");

  const absUrl = (u, base) => {
    try {
      return new URL(u, base || location.href).href;
    } catch (_e) {
      return null;
    }
  };

  const noHash = (u) => u.split("#")[0];

  // Labels that mark a label/value pair when a site uses plain divs or spans
  // instead of <th>/<td> or <dt>/<dd>.
  const LABELS = new Set([
    "価格", "販売価格", "物件価格", "所在地", "住所", "物件所在地", "交通", "沿線・駅", "最寄駅",
    "最寄り駅", "アクセス", "土地面積", "敷地面積", "建物面積", "延床面積", "延べ床面積",
    "建物延床面積", "専有面積", "間取り", "間取", "築年月", "築年数", "建築年月", "完成時期",
    "築年", "構造", "建物構造", "構造・工法", "構造・階建", "構造・規模", "階建", "階数",
    "建物階数", "土地権利", "権利", "権利形態", "土地の権利形態", "地目", "用途地域", "建ぺい率",
    "容積率", "建ぺい率・容積率", "建蔽率", "建蔽率・容積率", "接道", "接道状況", "道路", "前面道路",
    "私道負担", "私道負担・道路", "駐車場", "現況", "引渡", "引渡し", "引渡時期", "引渡可能時期",
    "取引態様", "設備", "備考", "都市計画", "地勢", "法令制限", "法令上の制限", "その他制限事項",
    "リフォーム", "総戸数", "管理費", "情報公開日", "情報登録日", "情報更新日", "次回更新予定日",
    "物件番号", "物件種目", "物件種別", "種別", "物件名", "学区", "会社名", "商号", "免許番号",
    "国土法届出", "セットバック", "建築確認番号", "総区画数", "区画面積", "水道", "ガス", "下水",
    "排水", "電気", "温泉", "管理会社", "別荘地名", "標高",
  ]);

  const labelKey = (s) => clean(s).replace(/[：:\s]/g, "").replace(/[（(].*$/, "");

  // ---------------------------------------------------------------- pairs

  // Nearest heading above an element, for grouping pairs into sections.
  const headingFor = (el) => {
    let node = el;
    for (let depth = 0; node && node !== document.body && depth < 8; depth++) {
      let sib = node.previousElementSibling;
      for (let i = 0; sib && i < 6; i++) {
        if (/^H[1-6]$/.test(sib.tagName)) return textOf(sib).slice(0, 80);
        const inner = sib.querySelector && sib.querySelector("h1,h2,h3,h4,h5,h6");
        if (inner && sib.querySelectorAll("*").length < 12) return textOf(inner).slice(0, 80);
        sib = sib.previousElementSibling;
      }
      node = node.parentElement;
    }
    return "";
  };

  // Label/value pairs under `root`, in document order.
  // Returns [{label, value, section}]. A label may repeat.
  const pairs = (root, opts) => {
    root = root || document.body;
    const withSection = !opts || opts.sections !== false;
    const found = [];
    const claimed = new Set();
    const push = (labelEl, label, value) => {
      // Portals append tooltip text ("ヒント") to labels on a second line.
      label = clean(label).split("\n")[0].replace(/[：:]\s*$/, "");
      value = clean(value);
      if (!label || !value || label.length > 40 || label === value) return;
      if (labelEl.closest("nav,header,footer")) return;
      found.push({ el: labelEl, label, value });
      claimed.add(labelEl);
    };

    for (const tr of root.querySelectorAll("tr")) {
      const cells = [...tr.children].filter((c) => c.tagName === "TH" || c.tagName === "TD");
      for (let i = 0; i < cells.length; i++) {
        if (cells[i].tagName !== "TH") continue;
        const vals = [];
        let j = i + 1;
        while (j < cells.length && cells[j].tagName === "TD") vals.push(textOf(cells[j++]));
        if (vals.length) push(cells[i], textOf(cells[i]), vals.join("\n"));
      }
      // Two-cell rows without <th>: accept when the first cell is a known label.
      if (cells.length === 2 && cells[0].tagName === "TD" && LABELS.has(labelKey(textOf(cells[0])))) {
        push(cells[0], textOf(cells[0]), textOf(cells[1]));
      }
    }

    for (const dt of root.querySelectorAll("dt")) {
      const vals = [];
      let n = dt.nextElementSibling;
      while (n && n.tagName === "DD") {
        vals.push(textOf(n));
        n = n.nextElementSibling;
      }
      if (vals.length) push(dt, textOf(dt), vals.join("\n"));
    }

    // Plain elements whose whole text is a known label; value is the next sibling.
    for (const el of root.querySelectorAll("div,span,p,li,b,strong,label,h3,h4,h5,em,i")) {
      if (claimed.has(el) || el.childElementCount > 1) continue;
      const own = textOf(el);
      if (own.length > 16 || !LABELS.has(labelKey(own))) continue;
      if (el.closest("th,dt")) continue;
      let val = "";
      const sib = el.nextElementSibling;
      if (sib && !LABELS.has(labelKey(textOf(sib)))) val = textOf(sib);
      if (!val && el.parentElement) {
        const whole = textOf(el.parentElement);
        if (whole.startsWith(own) && whole.length < 400) val = clean(whole.slice(own.length).replace(/^[：:]/, ""));
      }
      if (val && val.length < 2000) push(el, own, val);
    }

    found.sort((a, b) => (a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
    const seen = new Set();
    const out = [];
    for (const f of found) {
      const key = f.label + "\u0000" + f.value;
      if (seen.has(key)) continue;
      seen.add(key);
      const rec = { label: f.label, value: f.value };
      if (withSection) rec.section = headingFor(f.el);
      out.push(rec);
    }
    return out;
  };

  // ---------------------------------------------------------------- images

  const CHROME_IMG = /(logo|sprite|icon|ico_|_ico|btn|button|banner|bnr|spacer|blank|loading|arrow|pixel|tracking|favicon|noimage|no_image|nophoto|qr|badge|line_|twitter|facebook|instagram)/i;

  const largestFromSrcset = (srcset) => {
    let best = null;
    let bestScore = -1;
    for (const part of String(srcset || "").split(",")) {
      const m = part.trim().match(/^(\S+)(?:\s+([\d.]+)([wx]))?$/);
      if (!m) continue;
      const score = m[2] ? parseFloat(m[2]) * (m[3] === "x" ? 1000 : 1) : 0;
      if (score > bestScore) {
        bestScore = score;
        best = m[1];
      }
    }
    return best;
  };

  // Per-host rules that turn a thumbnail URL into the largest stored image.
  // Each returns candidate URLs, best first; the downloader keeps the largest
  // one that actually loads, so a wrong guess costs one request, not a photo.
  const UPSCALE = [
    {
      host: /(^|\.)suumo\.(jp|com)$/,
      // .../jj/resizeImage?src=gazo%2Fbukken%2F...jpg&w=..&h=.. is a view of
      // /front/gazo/bukken/...jpg (1000 px on the long side, the stored size).
      // suumo.jp and img01.suumo.com serve the same file; one host is named
      // so that both spellings count as one photo.
      fn: (u) => {
        const src = u.searchParams.get("src");
        if (/resizeImage/.test(u.pathname) && src) return [`https://img01.suumo.com/front/${src.replace(/^\/+/, "")}`];
        if (u.pathname.startsWith("/front/gazo/")) return [`https://img01.suumo.com${u.pathname}`];
        return [];
      },
    },
    {
      host: /(^|\.)homes\.(co\.jp|jp)$/,
      // .../smallimg/image.php?file=...&width=208&height=138: the resizer
      // returns at most 2400 px however much is asked for.
      fn: (u) => {
        if (!/image\.php$/.test(u.pathname) || !u.searchParams.has("file")) return [];
        const big = new URL(u.href);
        big.searchParams.set("width", "2400");
        big.searchParams.set("height", "2400");
        return [big.href];
      },
    },
  ];

  const sizeParamCandidates = (u) => {
    // Generic resizers: drop or enlarge width/height style parameters.
    const keys = ["w", "h", "width", "height", "size", "wd", "ht", "maxwidth", "maxheight"];
    if (!keys.some((k) => u.searchParams.has(k))) return [];
    const bare = new URL(u.href);
    const big = new URL(u.href);
    for (const k of keys) {
      if (!u.searchParams.has(k)) continue;
      bare.searchParams.delete(k);
      if (/^\d+$/.test(u.searchParams.get(k))) big.searchParams.set(k, "1600");
    }
    return [big.href, bare.href];
  };

  const bestCandidates = (url) => {
    let u;
    try {
      u = new URL(url);
    } catch (_e) {
      return [url];
    }
    const out = [];
    for (const rule of UPSCALE) if (rule.host.test(u.hostname)) out.push(...rule.fn(u));
    out.push(...sizeParamCandidates(u));
    out.push(url);
    return [...new Set(out.filter(Boolean))];
  };

  const looksLikeImage = (u) =>
    /\.(jpe?g|png|webp|gif|avif)(?:[?#&,]|$)/i.test(u) || /[?&](?:src|file|img|image)=[^&]*\.(jpe?g|png|webp|gif|avif)/i.test(u);

  const stripTags = (s) => clean(String(s || "").replace(/<[^>]*>/g, ""));

  // Attributes where galleries keep the real photo URL while the visible
  // <img> is a placeholder or has not been loaded yet.
  const LAZY_ATTRS = [
    "data-src", "data-original", "data-lazy", "data-lazy-src", "data-echo", "data-url", "data-image", "data-img",
    "data-zoom-image", "data-large", "data-full", "data-href", "data-bg", "data-background", "rel",
  ];

  const lazyUrl = (el) => LAZY_ATTRS.map((a) => el.getAttribute(a)).find((v) => v && looksLikeImage(v));

  const captionFor = (el) => {
    const fig = el.closest("figure");
    if (fig) {
      const cap = fig.querySelector("figcaption");
      if (cap) return textOf(cap);
    }
    let node = el.parentElement;
    for (let depth = 0; node && node !== document.body && depth < 4; depth++) {
      // A container that shows several different photos cannot caption one of them.
      const distinct = new Set();
      for (const i of node.querySelectorAll("img")) {
        const src = lazyUrl(i) || i.currentSrc || i.src || "";
        if (src && !/^data:/.test(src)) distinct.add(bestCandidates(absUrl(src) || src)[0]);
      }
      if (distinct.size > 1) break;
      const t = textOf(node);
      if (t && t.length <= 600) return t;
      if (t.length > 600) break;
      node = node.parentElement;
    }
    return "";
  };

  // Every image on the page that could be listing content, in document order.
  // One record per photo: a thumbnail, its lazy full-size reference and a
  // lightbox link to the same file are merged.
  // Returns [{url, candidates, alt, category, caption, section, w, h, shown, how, chrome, tiny}].
  const images = (root) => {
    root = root || document;
    const byPhoto = new Map();
    const add = (raw, el, how, extra) => {
      const url = absUrl(raw);
      if (!url || !/^https?:/.test(url) || /^data:/.test(raw)) return;
      const key = noHash(url);
      if (key === noHash(location.href)) return;
      const candidates = bestCandidates(key);
      const w = el.naturalWidth || 0;
      const h = el.naturalHeight || 0;
      const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
      const rec = {
        url: key,
        candidates,
        alt: clean(el.getAttribute("alt") || el.getAttribute("title") || ""),
        category: stripTags((extra && extra.category) || el.getAttribute("data-category") || ""),
        caption: stripTags((extra && extra.caption) || el.getAttribute("data-caption") || "") || captionFor(el),
        section: headingFor(el),
        w,
        h,
        shown: Math.round(rect.width) + "x" + Math.round(rect.height),
        how,
        // Site furniture by file name. Small size alone proves nothing: a
        // thumbnail is often the only reference to a full-size photo.
        chrome: CHROME_IMG.test(key.split("?")[0].split("/").slice(-2).join("/")),
        tiny: candidates.length === 1 && w > 0 && w < 120 && h > 0 && h < 120,
      };
      const prev = byPhoto.get(candidates[0]);
      if (!prev) {
        byPhoto.set(candidates[0], rec);
        return;
      }
      for (const field of ["alt", "category", "caption", "section"]) if (!prev[field] && rec[field]) prev[field] = rec[field];
      if (rec.w * rec.h > prev.w * prev.h) Object.assign(prev, { w: rec.w, h: rec.h, shown: rec.shown });
      prev.tiny = prev.tiny && rec.tiny;
    };

    const walker = root.querySelectorAll("img, picture source[srcset], a, input, [data-src], [data-image], [data-bg], [style*='background']");
    for (const el of walker) {
      const tag = el.tagName;
      if (tag === "IMG") {
        const fromSet = largestFromSrcset(el.getAttribute("srcset") || el.getAttribute("data-srcset"));
        add(fromSet || lazyUrl(el) || el.currentSrc || el.src, el, "img");
      } else if (tag === "SOURCE") {
        const best = largestFromSrcset(el.getAttribute("srcset"));
        if (best) add(best, el.parentElement.querySelector("img") || el, "source");
      } else if (tag === "INPUT") {
        // Some galleries list every photo in hidden inputs as "url,category".
        const m = (el.value || "").match(/^(https?:\/\/[^,\s]+?)(?:,([^/=]*))?$/);
        if (m && looksLikeImage(m[1])) add(m[1], el, "input", { category: m[2] || "" });
      } else {
        const href = el.getAttribute("href");
        if (tag === "A" && href && looksLikeImage(href)) add(href, el, "link");
        const lazy = lazyUrl(el);
        if (lazy) add(lazy, el, "attribute");
        const m = (el.getAttribute("style") || "").match(/background[^;]*url\((['"]?)(.*?)\1\)/);
        if (m) add(m[2], el, "background");
      }
    }
    return [...byPhoto.values()];
  };

  // ---------------------------------------------------------------- coords

  const inJapan = (lat, lon) => lat > 20 && lat < 46.5 && lon > 122 && lon < 154.5;

  // Coordinates the page exposes for its map. Returns candidates with the
  // text they came from; the caller decides which to trust.
  const coords = () => {
    const out = [];
    const seen = new Set();
    const add = (lat, lon, from, datum) => {
      lat = Number(lat);
      lon = Number(lon);
      if (!inJapan(lat, lon)) return;
      const key = lat.toFixed(5) + "," + lon.toFixed(5);
      if (seen.has(key)) return;
      seen.add(key);
      out.push({ lat, lon, from: String(from).slice(0, 160), datum: datum || "unknown" });
    };
    const html = document.documentElement.innerHTML;
    let m;
    const reQuery = /[?&](?:q|ll|sll|center|query|daddr|destination|markers|loc)=(?:[a-z]*:)?(-?\d{2}\.\d{3,})(?:,|%2C)\s*(-?\d{2,3}\.\d{3,})/gi;
    while ((m = reQuery.exec(html))) add(m[1], m[2], m[0], "wgs84");
    const reAt = /@(-?\d{2}\.\d{3,}),(-?\d{2,3}\.\d{3,})/g;
    while ((m = reAt.exec(html))) add(m[1], m[2], m[0], "wgs84");
    const reNamed = /["']?(?:lat|latitude)["']?\s*[:=]\s*["']?(-?\d{2}\.\d{3,})["']?[\s\S]{0,60}?["']?(?:lng|lon|long|longitude)["']?\s*[:=]\s*["']?(-?\d{2,3}\.\d{3,})/gi;
    while ((m = reNamed.exec(html))) add(m[1], m[2], m[0]);
    const reNamedRev = /["']?(?:lng|lon|long|longitude)["']?\s*[:=]\s*["']?(-?\d{2,3}\.\d{3,})["']?[\s\S]{0,60}?["']?(?:lat|latitude)["']?\s*[:=]\s*["']?(-?\d{2}\.\d{3,})/gi;
    while ((m = reNamedRev.exec(html))) add(m[2], m[1], m[0]);
    // Milliarcsecond pairs (ido = latitude, keido = longitude), often Tokyo datum.
    const reMs = /ido["']?\s*[:=]\s*["']?(\d{8,9})["']?[\s\S]{0,60}?keido["']?\s*[:=]\s*["']?(\d{9})/gi;
    while ((m = reMs.exec(html))) add(m[1] / 3600000, m[2] / 3600000, m[0], "milliarcsec");
    const reMsRev = /keido["']?\s*[:=]\s*["']?(\d{9})["']?[\s\S]{0,60}?ido["']?\s*[:=]\s*["']?(\d{8,9})/gi;
    while ((m = reMsRev.exec(html))) add(m[2] / 3600000, m[1] / 3600000, m[0], "milliarcsec");
    for (const el of document.querySelectorAll("[data-lat],[data-latitude]")) {
      add(
        el.getAttribute("data-lat") || el.getAttribute("data-latitude"),
        el.getAttribute("data-lng") || el.getAttribute("data-lon") || el.getAttribute("data-longitude"),
        "data-lat attribute",
      );
    }
    return out;
  };

  const jsonld = () => {
    const out = [];
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        out.push(JSON.parse(s.textContent));
      } catch (_e) {
        // Malformed JSON-LD is common and carries nothing we need.
      }
    }
    return out;
  };

  // ---------------------------------------------------------------- cards

  const PRICE = /([0-9０-９][0-9０-９,，.．]*\s*億\s*(?:[0-9０-９][0-9０-９,，.．]*\s*万)?|[0-9０-９][0-9０-９,，.．]*\s*万)\s*円|価格(?:応談|未定|相談)/;
  const AREA = /[0-9０-９][0-9０-９,，.．]*\s*(?:m2|m²|㎡|平米|坪)/i;
  const NOT_DETAIL = /(inquir|shiryou|siryo|contact|toiawase|favorite|okiniiri|request|mailto|login|print|kengaku|reserve|javascript:|\/map\/?$|tel:)/i;

  const urlShape = (href) => {
    const u = new URL(href);
    return u.hostname + u.pathname.replace(/[0-9]+/g, "#").replace(/[A-Za-z]*#[A-Za-z#_-]*/g, "#");
  };

  const lowestCommonAncestor = (els) => {
    let node = els[0];
    while (node && !els.every((e) => node.contains(e))) node = node.parentElement;
    return node || els[0];
  };

  // Result cards found without site knowledge: a card is the largest subtree
  // that links to exactly one detail page and mentions a price and an area.
  const guessCards = () => {
    const here = noHash(location.href);
    const byHref = new Map();
    for (const a of document.querySelectorAll("a[href]")) {
      const href = noHash(a.href || "");
      if (!/^https?:/.test(href) || href === here || NOT_DETAIL.test(href)) continue;
      if (!byHref.has(href)) byHref.set(href, []);
      byHref.get(href).push(a);
    }
    const byShape = new Map();
    for (const href of byHref.keys()) {
      const shape = urlShape(href);
      if (!byShape.has(shape)) byShape.set(shape, []);
      byShape.get(shape).push(href);
    }
    let best = null;
    for (const [shape, hrefs] of byShape) {
      const hrefSet = new Set(hrefs);
      const cards = [];
      for (const href of hrefs) {
        let el = lowestCommonAncestor(byHref.get(href));
        while (el.parentElement && el.parentElement !== document.body) {
          const p = el.parentElement;
          if ((p.innerText || "").length > 6000) break;
          let foreign = false;
          for (const a of p.querySelectorAll("a[href]")) {
            const h = noHash(a.href || "");
            if (h !== href && hrefSet.has(h)) {
              foreign = true;
              break;
            }
          }
          if (foreign) break;
          el = p;
        }
        const t = el.innerText || "";
        if (PRICE.test(t) && AREA.test(t)) cards.push({ el, href });
      }
      if (cards.length && (!best || cards.length > best.cards.length)) best = { shape, cards };
    }
    if (!best) return [];
    // Cards of one list share a tag and class even when some link elsewhere
    // (a promoted listing, a development page). Once most guessed cards agree
    // on a signature, take every element with that signature.
    const signature = (el) => el.tagName.toLowerCase() + [...el.classList].map((c) => "." + CSS.escape(c)).join("");
    const counts = new Map();
    for (const c of best.cards) counts.set(signature(c.el), (counts.get(signature(c.el)) || 0) + 1);
    const [common, n] = [...counts].sort((a, b) => b[1] - a[1])[0];
    if (!common.includes(".") || n < 0.6 * best.cards.length) return best.cards;
    const known = new Map(best.cards.map((c) => [c.el, c.href]));
    const all = [];
    for (const el of document.querySelectorAll(common)) {
      const t = el.innerText || "";
      if (!PRICE.test(t) || !AREA.test(t)) continue;
      const link = [...el.querySelectorAll("a[href]")].find((a) => /^https?:/.test(a.href) && !NOT_DETAIL.test(a.href));
      const href = known.get(el) || (link ? noHash(link.href) : null);
      if (href) all.push({ el, href });
    }
    return all.length >= best.cards.length ? all : best.cards;
  };

  const titleOf = (el, href) => {
    const h = el.querySelector("h1,h2,h3,h4,[class*='title'],[class*='ttl'],[class*='name']");
    if (h && textOf(h)) return textOf(h).slice(0, 200);
    let longest = "";
    for (const a of el.querySelectorAll("a[href]")) {
      if (noHash(a.href) === href && textOf(a).length > longest.length) longest = textOf(a);
    }
    return longest.slice(0, 200);
  };

  // Listing cards on a search-results page.
  // opts.selector: CSS selector for one card, when the generic guess is wrong.
  // opts.link: CSS selector, inside a card, of the link to the detail page.
  // Returns [{url, title, pairs, text, image}].
  const cards = (opts) => {
    opts = opts || {};
    let found;
    if (opts.selector) {
      found = [...document.querySelectorAll(opts.selector)].map((el) => {
        const a = (opts.link && el.querySelector(opts.link)) ||
          [...el.querySelectorAll("a[href]")].find((x) => /^https?:/.test(x.href) && !NOT_DETAIL.test(x.href));
        return { el, href: a ? noHash(a.href) : null };
      });
    } else {
      found = guessCards();
    }
    return found.map(({ el, href }) => {
      const img = images(el).find((i) => !i.chrome);
      return {
        url: href,
        title: titleOf(el, href),
        pairs: pairs(el, { sections: false }),
        text: textOf(el).slice(0, opts.textLimit || 1500),
        image: img ? img.url : null,
      };
    });
  };

  // Total hit count and the next-page URL of a results page.
  const pageInfo = (opts) => {
    opts = opts || {};
    let next = null;
    const relNext = document.querySelector("link[rel='next'], a[rel='next']");
    if (relNext && relNext.href) next = relNext.href;
    if (!next && opts.next) {
      const el = document.querySelector(opts.next);
      if (el && el.href) next = el.href;
    }
    if (!next) {
      for (const a of document.querySelectorAll("a[href]")) {
        const t = textOf(a);
        if (/^(次へ|次へ\s*[>＞›»]?|次の\s*\d*\s*件?\s*[>＞›»]?|次ページ|次のページ|次|[>＞›»]|next\s*[>›»]?)$/i.test(t) && /^https?:/.test(a.href)) {
          next = a.href;
          break;
        }
      }
    }
    let hits = null;
    const scope = opts.hits ? textOf(document.querySelector(opts.hits)) : textOf(document.body).slice(0, 20000);
    const m = scope.match(/(?:全|該当|検索結果|合計)?[^\d\n]{0,12}([0-9０-９][0-9０-９,，]*)\s*件(?!以上)/);
    if (m) hits = m[1];
    return { url: location.href, title: document.title, hits, next };
  };

  // ---------------------------------------------------------------- detail

  // Text on a detail page outside its tables: sales copy, agent comments,
  // remarks, and lists of short items (equipment, nearby facilities, tags).
  // A list is returned as one block with one item per line.
  const blocks = () => {
    const out = [];
    const seen = new Set();
    const lists = [];
    const skip = "nav,header,footer,script,style,noscript,select,table,dl,[class*='breadcrumb'],[class*='footer'],[class*='header'],[class*='gnav']";
    const push = (el, text, list) => {
      if (text.length < 30 || text.length > 4000 || seen.has(text)) return;
      seen.add(text);
      out.push(list ? { section: headingFor(el), text, list: true } : { section: headingFor(el), text });
    };
    for (const el of document.querySelectorAll("p,div,li,section,article,blockquote,ul,ol")) {
      if (el.closest(skip) || lists.some((l) => l.contains(el))) continue;
      if (el.tagName === "UL" || el.tagName === "OL") {
        const items = [...el.children].filter((c) => c.tagName === "LI");
        const texts = items.map(textOf).filter(Boolean);
        // A list made of links is navigation, not content.
        const linky = items.filter((li) => { const a = li.querySelector("a"); return a && textOf(a).length >= 0.8 * textOf(li).length; }).length;
        if (texts.length >= 3 && linky <= 0.7 * items.length) {
          lists.push(el);
          push(el, texts.map((t) => t.replace(/\n/g, " ")).join("\n"), true);
        }
        continue;
      }
      let direct = "";
      for (const n of el.childNodes) if (n.nodeType === 3) direct += n.nodeValue;
      if (clean(direct).length < 30 && !el.querySelector(":scope > br")) continue;
      push(el, textOf(el), false);
    }
    return out;
  };

  // Everything a listing page says about one property.
  const detail = () => {
    const h1 = document.querySelector("h1");
    const subpages = [];
    const base = noHash(location.href).replace(/\/?$/, "/");
    for (const a of document.querySelectorAll("a[href]")) {
      const href = noHash(a.href || "");
      if (href.startsWith(base) && href.length > base.length && !NOT_DETAIL.test(href)) {
        if (!subpages.some((s) => s.url === href)) subpages.push({ url: href, text: textOf(a).slice(0, 60) });
      }
    }
    const pdfs = [...document.querySelectorAll("a[href]")]
      .filter((a) => /\.pdf(\?|$)/i.test(a.href))
      .map((a) => ({ url: a.href, text: textOf(a).slice(0, 80) }));
    return {
      jpx: VERSION,
      url: location.href,
      title: document.title,
      h1: textOf(h1),
      captured_at: new Date().toISOString(),
      pairs: pairs(document.body),
      blocks: blocks(),
      images: images(document),
      coords: coords(),
      jsonld: jsonld(),
      subpages,
      pdfs,
    };
  };

  // Scroll through the page so lazy-loaded photos get their real URLs.
  const autoScroll = async (stepMs) => {
    const step = Math.max(400, Math.round(window.innerHeight * 0.8));
    const start = Date.now();
    for (let y = 0; y < document.documentElement.scrollHeight && Date.now() - start < 20000; y += step) {
      window.scrollTo(0, y);
      await new Promise((r) => setTimeout(r, stepMs || 120));
    }
    window.scrollTo(0, 0);
    return document.documentElement.scrollHeight;
  };

  // Wait until the page's text stops changing, for sites that render results with scripts.
  const settle = async (maxMs) => {
    const start = Date.now();
    let last = -1;
    let stable = 0;
    while (Date.now() - start < (maxMs || 8000)) {
      const size = document.body ? document.body.innerText.length : 0;
      stable = size === last && document.readyState !== "loading" ? stable + 1 : 0;
      if (stable >= 3) break;
      last = size;
      await new Promise((r) => setTimeout(r, 250));
    }
    return last;
  };

  // Links whose URL matches `pattern` (a regular expression source), with the
  // text around each, for reading an index page of cities or areas.
  const links = (pattern) => {
    const re = new RegExp(pattern);
    const out = [];
    const seen = new Set();
    for (const a of document.querySelectorAll("a[href]")) {
      const href = noHash(a.href || "");
      if (!re.test(href)) continue;
      // A listing count often sits beside the link, not inside it.
      const around = a.parentElement ? textOf(a.parentElement) : "";
      const text = around && around.length <= 60 ? around : textOf(a);
      const key = href + "\u0000" + text;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ href, text: text.slice(0, 80) });
    }
    return out;
  };

  // Signs that the site served a block page instead of content.
  const blocked = () => {
    const t = (document.title + " " + textOf(document.body).slice(0, 1500)).toLowerCase();
    const signs = ["access denied", "forbidden", "captcha", "are you a robot", "アクセスが集中", "アクセスを制限", "アクセスが制限", "不正なアクセス", "認証にご協力", "ロボットではありません", "しばらく時間をおいて", "request blocked", "just a moment", "verify you are human", "pardon our interruption"];
    return signs.filter((s) => t.includes(s));
  };

  window.JPX = { version: VERSION, pairs, images, coords, jsonld, cards, pageInfo, blocks, detail, links, settle, autoScroll, blocked, bestCandidates };
  return VERSION;
})();
