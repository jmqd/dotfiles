---
name: japan-property-search
description: Search Japanese real-estate sites for houses that match a buyer's criteria (structure, building area, lot size by zone, optional price and age) and report every candidate with its facts and links. Use when asked to find, search for, or monitor houses or villas for sale in Japan, to rerun a property search, or to see what is new since the last search. For an English brochure of one listing, use japan-property-brochure.
---

# Japan property search

Finds listed houses in Japan that meet a criteria profile, across portals,
brokers' own sites and local agencies. It reads result pages in a browser,
judges every listing, groups the copies of one house that different agents
and portals advertise, and writes a report of matches, near misses and
listings that leave a criterion unstated. Each run is compared with the last,
so the report says what is new, repriced or gone.

The default profile is the owner's standing brief: a second-hand detached
house in reinforced concrete (RC or SRC), 250 m² or more of floor area, on a
lot of 190 m² or more in Tokyo's 23 wards or 1,000 m² or more anywhere else.

## What you need

- Python 3.9 or later (standard library only).
- A browser you can drive. In omp that is the `browser` object in eval.
- This skill's directory, called `SKILL` below (the folder holding this file).
  All commands are `python3 SKILL/scripts/jpsearch <command>`.

Results live in a workspace that persists between runs: `$JP_PROPERTY_HOME`,
else `~/japan-property`. Pass `--home DIR` to use another.

## Rules that are not negotiable

1. **robots.txt decides what may be fetched.** The planner reads each host's
   robots.txt first and never plans a URL it disallows. A site that shuts
   out AI assistants by name is closed to this tool too. Do not fetch a
   disallowed URL another way.
2. **Human pace.** One page every 3 seconds per site at the fastest. No
   parallel requests to one site.
3. **No logins, no CAPTCHA solving, no disguises, no proxies.** When a site
   shows a block or challenge page, stop using it for this run and report it.
4. **Never submit a form** (inquiry, viewing request, registration).
5. **Unknown is not "no".** A listing that does not state its structure is
   `unverified`, never rejected and never a match. Say what is unknown and
   who would know.
6. **Do not loosen the criteria to produce results.** Zero matches is a
   result. Near misses are reported separately for the buyer to judge.
7. **Report coverage honestly.** Name every source that failed, was blocked
   or was not searched. A search of three sites is not a search of Japan.

## 1. Set up the criteria

```sh
python3 SKILL/scripts/jpsearch init          # creates the workspace and profile.json once
```

Read `<home>/profile.json`. If the request changes the criteria (a price
ceiling, other areas, another structure), edit that file; `references/profile.md`
explains each field. State the criteria you are searching with before you
start, including these two defaults: a house sold with a tenant in place, or
described as something other than a dwelling (a warehouse, a company
retreat), is listed for review, not as a match. If the request is ambiguous
about something the profile cannot express, ask once.

## 2. Run the automated sources

`jpsearch sources` lists the registry. Sources marked `auto` have a search
this tool can run.

In omp, in a JavaScript eval cell (the first line is a cell of its own):

```js
%load "SKILL/scripts/collect.omp.js"
```
```js
await jpCollect({ skill: "SKILL" })   // options: home, run, retryFailed, maxRounds
```

Give the second cell a long timeout (3600 s). It loops: plan, fetch every
page the plan marks `todo`, plan again, until nothing is left; then it
builds the report and returns `{ loaded, finished, left, summary }`. It can
be interrupted and called again; fetched pages are kept.

- A page whose load fails is fetched once more. A site that fails three
  times in a row is left alone for the rest of the call and named in `left`;
  call `jpCollect` again later to resume it.
- A run reads at most `max_detail_pages` detail pages (400 by default), the
  most promising first. The rest are reported as left for a later run.
- A national run with that limit takes one to two hours, almost all of it
  waiting between page loads. To try a small run first, set `"areas"` in
  the profile to one or two prefectures.

Without omp, do the same loop by hand: `references/collecting.md` gives the
contract (what to open, what to evaluate in the page, where to save it).

## 3. Read the sites that need a person's browser

Some of the largest portals (at home, LIFULL HOME'S) show a CAPTCHA to an
automated browser. Do not fight it. They are listed with `access: blocked`
and a `manual` note. Ask the owner whether to include them; if yes:

1. The owner opens the site's search in their own Chrome, sets the filters
   the note gives, and tells you when the results are on screen.
2. Borrow that tab without navigating it, run the extractor, and file the
   result:

   ```js
   const tab = await browser.open({ name: "athome", app: "relay", target: "athome.co.jp" });
   await tab.evaluate(await Bun.file("SKILL/scripts/jpx.js").text());
   const page = await tab.evaluate(`({ info: JPX.pageInfo(), cards: JPX.cards() })`);
   await Bun.write("/tmp/athome-1.json", JSON.stringify(page));
   ```
   ```sh
   python3 SKILL/scripts/jpsearch add list /tmp/athome-1.json --source athome --prefecture 東京都
   ```
3. The owner pages forward; repeat. For a listing that looks right, have the
   owner open it, capture `JPX.detail()` the same way, and file it with
   `jpsearch add detail FILE --source athome`.

If the owner is not available, skip these sources and say so in the report.

## 4. Browse the manual sources

Local agencies and specialist brokers hold houses the portals never see, and
large RC houses are a specialist's stock. `jpsearch sources --mode manual
--area 長野県` lists the ones covering a prefecture, most productive first,
with their kind (broker, luxury, resort, rural, design, auction) and whether
an automated browser can read them; `jpsearch sources --id ID` prints how to
search one. Leave alone the ones marked `blocked` or `disallowed` unless the
owner browses them (step 3).

For each manual source that covers the profile's areas, in that order:

1. Check its robots.txt allows the page (`jpsearch robots FILE URL`, with the
   robots.txt text saved to FILE), then open the search URL from its note.
2. Run `JPX.cards()`. Check the count against what the page shows. If it is
   wrong, pass the card selector from the note: `JPX.cards({ selector })`.
3. File the page with `jpsearch add list FILE --source ID`. Follow the
   site's paging while results could still qualify.
4. Open each listing that could qualify and file `JPX.detail()` with
   `jpsearch add detail FILE --source ID`.

Wait 3 seconds between pages on one site. A site not in the registry can be
filed under a new short id; it will appear in the coverage table.

Budget your effort: the registry orders sources by how many matching houses
they held when last checked. Stop a site when a page of results sorted by
size has fallen below the thresholds.

## 5. Build and check the report

```sh
python3 SKILL/scripts/jpsearch build
```

It prints counts and writes, under `<home>/search/runs/<date>/`:

| File | Use |
|---|---|
| `report.html` | The report to give the owner: matches, near misses and points to confirm, unverified, delisted, ruled out (an earlier candidate that is still listed and that this run rejects, with the reason), coverage, and the sources not searched. |
| `report.md` | The same in brief, for the chat reply. |
| `candidates.csv`, `candidates.json` | Every candidate with all fields and every listing URL. |
| `rejected.csv` | Every rejected listing and why. |
| `coverage.json` | What each source yielded, what failed and what was left unread. |

Before you hand it over:

- **Open two or three matches' listing pages** and confirm price, areas and
  structure against the report. If they disagree, the site's markup has
  drifted: see `references/troubleshooting.md`.
- **Read the coverage section.** A source marked `failed`, `partial` or
  `incomplete` needs a line in your reply, and so does the count of sources
  not searched. A source that returned no cards where it always has some is
  broken, not empty. `references/troubleshooting.md` says what each outcome
  means and what to do.
- **Resolve what you can of `unverified`.** Each card states its open point.
  If a detail page was left unread, resume the run. If the listing truly
  does not state its structure, leave it unverified and name the agent to
  ask.
- **Look at the near misses.** Each says what stands between it and a
  match: an area just under a minimum, a mixed structure, a tenant in
  place, a building that may not be a dwelling, or agents who disagree.
- **Add a one-line English note to each match** so the owner can scan them:
  `jpsearch mark ID --note "Karuizawa, 1990 RC villa on a wooded 2,200 m² lot; SRC per the detail page"`.
  Then run `build` again.

The owner's own marks persist between runs:
`jpsearch mark ID shortlist`, `jpsearch mark ID dismissed`, `jpsearch mark ID clear`.

## 6. Reply

Lead with the count of matches and what changed since the last run. Then:

- each match in a line or two: price, areas, year, structure, place, link;
- near misses and unverified candidates, with the open point for each;
- coverage: sources searched, sources that failed and why, sources left for
  the owner's browser, and how many sources were not searched at all;
- the path of `report.html`.

Offer an English brochure of any listing through the
`japan-property-brochure` skill, giving it the listing's URL.

## Reference

- `references/profile.md`: every field of the criteria profile, the
  statuses and the flags.
- `references/collecting.md`: the plan file and capture file formats, for
  running the loop without omp or for debugging it.
- `references/troubleshooting.md`: what each outcome means, failed sources,
  markup drift, and adding or fixing a source in `<home>/sources.json`
  without touching the skill.
- `jpsearch sources`: the source registry (`references/sources.json` for
  the sites this tool searches, `references/sources-manual.json` for the
  sites a person browses).
