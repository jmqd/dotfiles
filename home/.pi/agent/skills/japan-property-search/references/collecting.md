# Collecting pages

`scripts/collect.omp.js` runs this loop in omp. This file is the contract it
follows, for running the loop with another browser tool and for debugging.

## The loop

1. `jpsearch plan` writes `<home>/search/runs/<run>/plan.json` and prints its
   path on a line starting `plan: `.
2. Fetch every task whose `status` is `todo`, as described below.
3. Repeat from 1 until no task is `todo`.
4. `jpsearch build`.

The plan is worked out again each time from the profile, the registry and the
capture files on disk. A capture can add tasks: a robots.txt unlocks a site,
a results page adds the next page, a card adds its detail page. A task whose
capture file exists is not planned again, so the loop ends, and it can be
stopped and resumed at any point.

The loop decides nothing. Which URLs may be fetched, when paging stops, which
detail pages are worth reading and whether a failed page is tried again are
the planner's decisions.

## Rules while fetching

- One site at a time per browser tab, in plan order. Different sites may run
  side by side.
- After each page, wait the task's `delay_seconds` before the next page on
  that site.
- Fetch only `todo` tasks. `waiting` tasks are waiting for their site's
  robots.txt; `disallowed` tasks must not be fetched at all.
- When a site fails or shows a block page three times in a row, stop using it
  for this session. Leave its remaining tasks unfetched; write nothing for
  them.
- Never log in, submit a form, solve a CAPTCHA or change the browser's
  identity.

## Tasks

```json
{
  "id": "list:suumo:used_house:tokyo:p1",
  "kind": "list",
  "source": "suumo",
  "host": "suumo.jp",
  "url": "https://suumo.jp/chukoikkodate/tokyo/nj_316/?kb=1&hb=150&tb=150&po=10&pj=2&pc=100&page=1",
  "out": "search/runs/2026-11-25/raw/list/suumo/used_house-tokyo-p01.json",
  "status": "todo",
  "why": "",
  "attempt": 1,
  "delay_seconds": 3,
  "extract": { "fn": "list", "card": ".property_unit", "link": null, "hits": ".pagination_set-hit", "next": null }
}
```

| `status` | Meaning |
|---|---|
| `todo` | Fetch it. `attempt` above 1 means an earlier load failed and this is the retry. |
| `done` | Captured. |
| `waiting` | Its site's robots.txt has not been read yet. |
| `disallowed` | robots.txt forbids the URL, or robots.txt could not be read. |
| `failed` | Captured, but the page was a block page, an error page or unreadable; or its load failed twice. `why` says which. |
| `gone` | A listing page that says the listing is no longer there. |
| `deferred` | A detail page beyond the run's `max_detail_pages`. |
| `skipped` | A search this profile cannot use. |

## Fetching one task

Open `url` and wait until the HTML has been parsed to the end
(`document.readyState` is not `loading`). A page read while still loading
holds only its first cards.

Then, in the page:

1. For every kind but `robots`, evaluate `scripts/jpx.js`. It defines
   `window.JPX` and changes nothing.
2. Evaluate the expression for `extract.fn`:

| `fn` | Expression (async) | Result |
|---|---|---|
| `robots` | `fetch(location.href)` and read status and text | `{ status, text }` |
| `links` | `await JPX.settle(); ({ blocked: JPX.blocked(), links: JPX.links(extract.pattern) })` | Links to a prefecture's municipalities |
| `inputs` | `await JPX.settle(); ({ blocked: JPX.blocked(), inputs: JPX.values(extract.selector) })` | A search form's municipality codes |
| `list` | `await JPX.settle(); ({ blocked: JPX.blocked(), info: JPX.pageInfo({ hits: extract.hits, next: extract.next }), cards: JPX.cards({ selector: extract.card, link: extract.link }) })` | A results page |
| `detail` | `await JPX.settle(); await JPX.autoScroll(); Object.assign(JPX.detail(), { blocked: JPX.blocked() })` | One listing |

Write the capture to `<home>/<out>` as one JSON object:

```json
{
  "task": { "…": "the task, as planned" },
  "attempt": 1,
  "fetched_at": "2026-11-25T09:12:44.000Z",
  "final_url": "https://…",
  "http_status": 200,
  "error": null,
  "result": { "…": "what the expression returned" }
}
```

- `http_status` is the status of the page itself
  (`performance.getEntriesByType("navigation")[0].responseStatus`).
- When the load fails, times out, or answers with a status of 400 or more
  other than 404 and 410, set `error` to one line saying so and `result` to
  `null`. The planner queues the page once more. Leave 404 and 410 as they
  are: for a listing they mean it was withdrawn.
- Captures are never edited afterwards. A parsing fix is applied by running
  `jpsearch build` again over the same files.

## Pages read by hand

A results page or a listing read outside the plan, in the owner's browser or
on a site with no automated search, is filed with:

```sh
python3 SKILL/scripts/jpsearch add list FILE --source ID [--prefecture 長野県]
python3 SKILL/scripts/jpsearch add detail FILE --source ID
```

`FILE` holds `{ "info": JPX.pageInfo(), "cards": JPX.cards() }` for a results
page, or the output of `JPX.detail()` for a listing. `--prefecture` names the
prefecture a results page was filtered to, for sites whose cards give only
the town. `ID` is a registry id, or a new short id for a site the registry
does not hold.

## What JPX offers

| Call | Returns |
|---|---|
| `JPX.cards({ selector, link })` | Result cards: `[{ url, title, pairs, text, image }]`. Without a selector it finds the cards itself. Check the count against the page. |
| `JPX.pageInfo({ hits, next })` | `{ url, title, hits, next }`: the hit count and next-page link. |
| `JPX.detail()` | One listing: `pairs` (label and value), `blocks` (free text), `images`, `coords`, `subpages`, `pdfs`. |
| `JPX.pairs(element)` | Label and value pairs under an element. |
| `JPX.links(pattern)`, `JPX.values(selector)` | Links matching a pattern; the values of form controls. |
| `JPX.blocked()` | Phrases on the page that mark a block or CAPTCHA page. Empty when there are none. |
| `JPX.settle()`, `JPX.autoScroll()` | Wait for a script-rendered page; scroll so lazy photos load. |

JPX returns the page's text as written. Numbers, dates, structures and the
criteria are all read by the Python tools.
