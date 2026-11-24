# When something goes wrong

Start with the coverage section of the report, or
`<home>/search/runs/<run>/coverage.json`. Every source has an outcome and, if
it is not `searched`, the reason.

## Outcomes

| Outcome | Meaning | What to do |
|---|---|---|
| `searched` | Every planned page was read. | Nothing. |
| `incomplete` | Pages are still unfetched. | Call `jpCollect` again; it resumes. |
| `partial` | Some pages failed, or detail pages were deferred. | Read the note. See below. |
| `failed` | No results page could be read. | See "A whole source failed". |
| `not applicable` | The site's search cannot express this profile. | Browse it by hand: `jpsearch sources --id ID`. |
| `no search for these areas` | The site has no automated search in the profile's prefectures. | Nothing, or browse it by hand. |
| `skipped by profile` | `sources` or `exclude_sources` leaves it out. | Nothing. |
| `browsed by hand` | Pages were filed with `jpsearch add`. | Nothing. |
| `manual` | No automated search exists. | Browse it by hand if it covers the areas. |

## Pages that failed to load

A load that fails or times out is fetched once more in the same run. After
two failures the page is `failed`. To try such pages again later:

```js
await jpCollect({ skill: "SKILL", retryFailed: true })
```

A site that fails three times in a row is left alone for the rest of the
call. Its pages stay `todo`, the source shows `incomplete`, and the next
`jpCollect` call picks them up. Some sites are slow or drop requests at busy
hours (不動産ジャパン answers 502 now and then); a later call usually
succeeds.

## Detail pages left for a later run

A run reads at most `max_detail_pages` detail pages. Houses beyond that are
listed as `unverified` with the open point "its detail page was left for a
later run". Call `jpCollect` again on a later day (a new run reuses the
detail pages already read), or raise `max_detail_pages` in the profile and
call it again now.

## A whole source failed

| Note | Cause | Remedy |
|---|---|---|
| `block page: …` | The site challenges automated browsers. | Do not work around it. Use the owner's browser (SKILL.md, step 3) or leave the source out and say so. |
| `robots.txt disallows this URL` | The site forbids the search path. | Nothing to fix. The owner may browse it; the tool will not. |
| `robots.txt returned HTTP 403` or could not be loaded | The site refuses automated visitors, or was down. | Try again later. If it persists, treat it as blocked. |
| `the search URL returned HTTP 404` | The site changed its URL form. | Fix the source, below. |
| `cards found but neither price nor area could be read` | The site changed its markup. | Fix the source, below. |
| `page reports N hits but no cards were recognised` | The card selector no longer matches. | Fix the source, below. |
| `page is incomplete: N of M cards arrived` | The page was cut short while loading. | `jpCollect({ …, retryFailed: true })`. |
| `no municipalities found on the index page` | The index page changed. | Fix the source's `discover`, below. |
| `the site answered with an error page` | A server error that looked like a page. | Try again later. |

## Checking a result against the page

If a report value disagrees with the listing page, find out which side is
wrong before trusting either:

1. The capture is in `<run>/raw/detail/` (the file name is in `plan.json`
   beside the URL). Its `pairs` hold what the page said when it was read.
2. If the capture has the right value, the listing changed since, or the
   parser misread it. Open the listing, compare, and tell the owner which.
3. If the capture has the wrong value, the page's markup misled the
   extractor. Run `JPX.pairs(document.body)` on the page and look at the
   label in question.

Do not edit a capture. A wrong reading is corrected in the tools, and until
then by a note: `jpsearch mark ID --note "listing says 412 m², report misread it"`.

## One house shown twice, or two houses shown as one

Listings are grouped as one house when they agree on the lot and the floor
area, or on the lot or floor area with the build date and price, or on the
lot and price within one chōme. Agents who quote different areas for one
house, with no other figure in common, stay separate; say so in your reply
and dismiss one (`jpsearch mark ID dismissed --note "same house as pXXXX"`).
A wrong merge is rarer; check the listing links on the card, and report it.

## Fixing or adding a source without touching the skill

`<home>/sources.json` is laid over the shipped registry. An entry with the
id of a shipped source replaces it; a new id adds a source. The file has the
registry's form:

```json
{
  "sources": [
    {
      "id": "karuizawa-sato",
      "name": "Sato Real Estate, Karuizawa",
      "kind": "resort",
      "home": "https://sato.example/",
      "areas": ["長野県"],
      "rank": 2,
      "access": "ok",
      "manual": "Open https://sato.example/bessou/?sort=area and read cards with JPX.cards()."
    }
  ]
}
```

That is a source to browse by hand. To make it searchable, add `searches`:

```json
"searches": [
  {
    "listing_type": "used_house",
    "scope": "prefecture",
    "url": "https://sato.example/{pref}/houses?min_floor={building_min}&min_land={land_min}&sort=floor_desc&page={page}",
    "pref_format": "romaji",
    "prefectures": ["長野県"],
    "building_min": "free",
    "land_min": [0, 300, 500, 1000],
    "sorted_by": "building_desc",
    "per_page": 20,
    "hints": { "card": "li.estate", "link": "a.detail", "hits": ".count" }
  }
]
```

| Key | Meaning |
|---|---|
| `scope` | `nationwide` (one URL), `prefecture` (one per prefecture) or `city` (one per municipality). |
| `url` | Placeholders: `{pref}`, `{city}`, `{cities}`, `{building_min}`, `{land_min}`, `{page}`, `{offset}`. |
| `pref_format` | How `{pref}` is written: `romaji` (nagano), `code` (20), `ja` (長野県) or `slugs` (only the values in `pref_slugs`). |
| `pref_slugs` | Exceptions, or with `slugs` the whole list: `{ "北海道": "hokkaido_" }`. |
| `prefectures` | The prefectures the site covers. Omit for all. |
| `building_min`, `land_min` | What the site's filter accepts: `"free"` (any number), `{ "free_up_to": 500 }`, a list of the only values it takes, or omitted when there is no filter. The planner sends the tightest value that hides nothing. |
| `fixed_building_min` | The URL itself only returns buildings this large; the search is skipped for profiles that want smaller ones. |
| `sorted_by` | `building_desc` or `land_desc` when the URL sorts largest first. Paging then stops once the list has fallen below the threshold. |
| `per_page`, `page_first`, `max_pages` | Paging. Without `{page}` in the URL, the page's own next link is followed. |
| `cities_param`, `cities_per_url` | With `{cities}`: the parameter repeated for each municipality (omit it for a comma-separated list), and how many fit in one URL. |
| `discover` | Where to learn a prefecture's municipalities: `{ "url": "…{pref}…", "link": "regex with one group" }` or `{ "url": "…", "inputs": "CSS selector of the form controls" }`. |
| `hints` | CSS selectors: `card` for one result, `link` for its detail link, `hits` for the hit count, `next` for the next-page link. Omit what `JPX.cards()` finds by itself. |

Check the entry: `jpsearch sources --id ID` prints it, and after
`jpsearch plan` the plan file holds the first URL it will fetch. Verify the
site's robots.txt allows that URL (`jpsearch robots FILE URL`) before
relying on it; the planner checks again at run time.

## Starting a run over

Captures live in `<home>/search/runs/<run>/`. To redo a run, move that
directory away and start again; `state.json` keeps the history of earlier
runs and need not be touched. To fetch one page again, move its capture file
away and call `jpCollect`.
