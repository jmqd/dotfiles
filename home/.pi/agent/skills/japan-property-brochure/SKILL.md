---
name: japan-property-brochure
description: Turn one Japanese property listing into an English PDF brochure, with every photo, the floor plan and lot plan with their labels translated, location maps, and the full property details. Use when asked for an English brochure, translation or summary document of a specific house, villa or land listing in Japan, given its URL (SUUMO, at home, LIFULL HOME'S, a broker's or agency's site) or files the owner supplies. To find listings in the first place, use japan-property-search.
---

# Japan property brochure

Makes an English brochure of one listing: a cover with the key facts, the
property details with the Japanese originals beside them, every photo with
its caption, the floor plan and lot plan with what is printed on them, an
aerial photograph and area map, the neighbourhood, the agent, and
translator's notes. The result is `brochure.pdf`, typeset for A4.

The brochure is a translation. It says what the listing says, completely and
plainly, and nothing else. It is for the owner's own use: the photos and text
belong to the listing's publisher, the source is named on the cover, and it
is not for publishing or passing on.

## What you need

- Python 3.9 or later (standard library only).
- A browser you can drive, to read the listing page. In omp that is the
  `browser` object in eval.
- Chrome or Chromium on the machine, to render the PDF (`$CHROME` overrides
  the search).
- This skill's directory, called `SKILL` below. All commands are
  `python3 SKILL/scripts/brochure <command>`.

## 1. Capture the listing

```sh
python3 SKILL/scripts/brochure new minami-ogikubo-rc     # prints the brochure folder, DIR below
```

In omp, in a JavaScript eval cell (the first line is a cell of its own):

```js
%load "SKILL/scripts/capture.omp.js"
```
```js
await jpCapture({ skill: "SKILL", dir: "DIR", url: "https://suumo.jp/chukoikkodate/tokyo/sc_suginami/nc_20645338/" })
```

It reads the site's robots.txt first and stops if that keeps automated
browsers out of the listing. Then it reads the listing page and the
sub-pages it links to (overview, surroundings, equipment) and saves each as
`DIR/capture/NN-name.json`. It skips the agent's shop page. Three seconds
pass between pages.

If robots.txt refuses, or the site shows a block or CAPTCHA page (at home and
LIFULL HOME'S do this to automated browsers), do not work around it. Ask the
owner to open the listing in their own Chrome, then read that tab as it
stands:

```js
await jpCapture({ skill: "SKILL", dir: "DIR", target: "homes.co.jp/kodate/b-1243260010078" })
```

A borrowed tab is never navigated, so only the page on screen is captured;
ask the owner to open any sub-page that matters and capture it the same way.
Without omp, evaluate `SKILL/scripts/jpx.js` in the page and save the output
of `JPX.detail()` as `DIR/capture/01-main.json`.

The same property on a second site can add photos or details: capture it
into the same folder with `start` set to the next free number
(`jpCapture({ ..., url: "…", start: 5 })`). The first capture is the
brochure's source of record.

## 2. Merge, download, look

```sh
python3 SKILL/scripts/brochure ingest DIR    # capture/*.json -> listing.json
python3 SKILL/scripts/brochure photos DIR    # every photo, largest stored size
python3 SKILL/scripts/brochure sheets DIR    # contact sheets, 12 photos each
python3 SKILL/scripts/brochure maps DIR      # aerial photograph and area map
```

- **`ingest`** prints how many fields and photos it found. Compare the photo
  count with the listing's own ("写真 48枚"). If photos are missing, the
  gallery loaded lazily: capture the page again. Run it again after every
  new capture: a photo keeps its id, and new photos take new ids.
- **`photos`** downloads politely and checks robots.txt for each image host.
  A photo it reports as failed must be saved from the browser and registered
  with `brochure add-photo DIR FILE --id pNNN`, or accounted for later.
- **`sheets`**: read every `DIR/sheets/sheet-NN.png`. This is how you see all
  the photos. Then open at full size each floor plan, lot plan,
  specification sheet and map in `DIR/photos/`, because you will transcribe
  them.
- **`maps`** uses the coordinates the listing page exposes. If it has none,
  pass `--address '東京都杉並区南荻窪1'` (the map is then centred on the
  district, not the lot) or `--lat` and `--lon`. Open the aerial tiles and
  check the marker sits where the address says.

Files the owner supplies go in the same way: `brochure add-photo DIR FILE
--category "sales sheet"` (convert a PDF page or a HEIC photo to JPEG first,
with `sips -s format jpeg` on macOS).

## 3. Translate

```sh
python3 SKILL/scripts/brochure draft DIR     # brochure.json, every Japanese string marked "JA: "
```

The draft places every field and every photo. Rewrite `DIR/brochure.json`
into the finished English content: translate each `JA: ` string, regroup the
rows and photos into sections, and prune what is not about the property.
`references/brochure-json.md` defines the file and the section types;
`references/glossary.md` fixes the English for listing terms. Read both
before you start.

### How to translate

- **Translate; do not write.** No praise the listing does not contain, no
  advice, no assessment, no guesses. What the agent claims stays the agent's
  claim ("From the agent").
- **Leave nothing out.** Every field, caption and photo of the listing is in
  the brochure or is listed as omitted with a reason. The build enforces
  this.
- **Numbers are copied, then converted.** Keep the listing's figure and add
  the conversion: `409.22 m² (123.78 tsubo)`, `¥488,000,000 (4億8,800万円)`,
  `40.4 jō (about 65 m²)`. Dates become `June 2006`; era years become
  Western years.
- **Legal and administrative terms keep their Japanese.** Zoning, tenure,
  restrictions, licence numbers: give the glossary's English and put the
  original in the row's `ja`, so the owner can look the term up or quote it
  to an agent.
- **Names** are romanised in Hepburn with macrons (Ogikubo, Chūō, Kichijōji),
  with the Japanese in brackets the first time.
- **Plain English.** Drop decoration (♪, ！, ★) and repeated sales phrases.
  Keep disclosures the agent makes, such as "the furniture is
  computer-generated", as the photo's `note`.
- **Report contradictions; do not resolve them.** When the headline says two
  minutes and the agent's message says one, both stay as written and the
  conflict goes under "Left as written in the source".
- **Blank fields are facts.** A dash on the listing becomes "Not stated".
  List them; they are the questions to ask the agent.

### Photos, plans and maps

- **Photos** stay in the listing's order. `label` is the listing's category
  for the photo, `caption` its caption. Say so when the listing repeats an
  image or gives a caption that belongs to another photo.
- **Floor plans:** transcribe what is printed, floor by floor: every room
  with its size, stairs, voids, storage, the compass.
- **Lot plans:** every road with its width and side, every dimension, the
  compass, and what is drawn on the lot (parking, garden, setback line).
- **Specification sheets and other text-bearing images:** translate the text
  on them as `labels`.
- **Maps:** say where the marker came from and how exact it is. A listing's
  map position is usually a nearby address, not the lot.
- **Images that are not the property** (gift promotions, staff, the agent's
  brochure sample) go in their own section or in `omitted_photos`.

### Order of sections

Highlights, property details, photos, floor plan, specification sheets, lot
plan, location maps, equipment, feature tags, neighbourhood, the agent's
services, the listing company and agent, the site's standard notes,
translator's notes. Leave out a section the listing has nothing for.

## 4. Build and review

```sh
python3 SKILL/scripts/brochure build DIR     # brochure.html, brochure.pdf, pages/page-NNN.jpg
```

The build stops with a list when a photo is unaccounted for, a `JA: ` string
remains, or a section is malformed. It warns about listing fields that no
row names; clear the warning by adding the row or by listing the label in
`ignored_labels` (site navigation and form fields only).

Then look at every page image in `DIR/pages/`. Check:

- the cover: title, six facts and source line are right against
  `listing.json`;
- no photo is missing, stretched or cropped through its subject (set
  `"fit": "contain"` for a plan, map or document);
- plan pages: the image is legible and its labels table is complete;
- tables: no row is cut off and no Japanese text overflows;
- no page is mostly empty (remove a stray `"new_page": true`);
- the footer and page numbers are present.

Fix `brochure.json` and build again until every page is right.

## 5. Deliver

Give the owner the path of `DIR/brochure.pdf`, the page count, and two or
three lines on what the listing leaves unstated or contradicts itself on.
For hazards, terrain and climate at the site, point to the land report
skill; this brochure does not assess the property.

## Reference

- `references/brochure-json.md`: the content file and every section type.
- `references/glossary.md`: the English for Japanese listing terms.
- `python3 SKILL/scripts/brochure status DIR`: which steps are done.
