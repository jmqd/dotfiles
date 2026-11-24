# brochure.json

`brochure.json` is the English content of the brochure. `brochure draft`
writes a first version from `listing.json` in which every string that still
needs translating starts with `JA: `. You rewrite it; `brochure build` checks
it and lays it out. The build adds no wording of its own.

All text is plain text. A line break in a string becomes a line break on the
page. There is no markup.

## Top level

```json
{
  "eyebrow": "SUUMO listing no. 20645338 · English translation",
  "title": "Custom-built reinforced-concrete home, two minutes' walk from the bus stop",
  "subtitle": "A resort-like space wrapped in light and greenery.",
  "tagline": "RC construction × custom-built · Two-family or rental use possible",
  "short_name": "Minami-Ogikubo 1-chōme RC house",
  "source": {
    "site": "SUUMO",
    "url": "https://suumo.jp/chukoikkodate/tokyo/sc_suginami/nc_20645338/",
    "listing_id": "20645338",
    "information_date": "23 November 2026",
    "next_update": "1 December 2026",
    "translated_on": "25 November 2026"
  },
  "hero_photo": "p001",
  "key_facts": [
    { "label": "Price", "value": "¥488,000,000", "note": "4億8,800万円" },
    { "label": "Layout", "value": "5LLDDKK + 2S", "note": "5 bedrooms, 2 living, 2 dining, 2 kitchens, 2 storerooms" },
    { "label": "Building", "value": "540.53 m²", "note": "163.50 tsubo" },
    { "label": "Land", "value": "409.22 m²", "note": "123.78 tsubo, registered" },
    { "label": "Built", "value": "June 2006", "note": "RC, 3 storeys" },
    { "label": "Station", "value": "Ogikubo, 13 min walk", "note": "JR Chūō Line" }
  ],
  "summary": "Second-hand detached house · Minami-Ogikubo 1-chōme, Suginami-ku, Tokyo · Immediate handover",
  "sections": [],
  "omitted_photos": [{ "photo": "p038", "reason": "the agent's gift promotion, not the property" }],
  "ignored_labels": ["お名前", "メールアドレス"]
}
```

| Field | Required | Meaning |
|---|---|---|
| `eyebrow` | yes | Small line above the title: site, listing number, "English translation". |
| `title` | yes | The listing's own headline, translated. Not a headline you wrote. |
| `subtitle`, `tagline` | no | The listing's lead sentence and its string of catch phrases. |
| `short_name` | yes | Short English name for the page footer. |
| `source.site`, `source.url`, `source.translated_on` | yes | Where the listing is and when you translated it. |
| `source.listing_id`, `information_date`, `next_update` | no | Shown on the cover when present. |
| `hero_photo` | no | Photo id for the cover. Use the listing's own first photo unless it is a plan. |
| `key_facts` | yes, 3 to 9 | Cover grid, three per row. `note` is the small line under the value. |
| `summary` | no | One line under the grid: type, address, handover, agent. |
| `sections` | yes | The body, in order. See below. |
| `omitted_photos` | when any | Every photo you leave out, with the reason. |
| `ignored_labels` | when any | Japanese labels in `listing.json` that are not about the property (form fields, site navigation). |

## Accounting rules the build enforces

- **Every photo is placed or explained.** Each id in `photos.json` must appear
  in a section (or as `hero_photo`) or in `omitted_photos` with a reason. A
  photo whose download failed must be fixed with `brochure add-photo` or
  listed in `omitted_photos`.
- **No draft text remains.** Any string still starting with `JA: ` stops the
  build and is listed with its path.
- **Fields are accounted for.** The build warns about every label in
  `listing.json` that no table row names in `ja_label` and that is not in
  `ignored_labels`. Clear the warning by adding the row or by listing the
  label as ignored. Do not ignore a label that describes the property.

## Sections

Every section has `type` and `title`. `intro` (a muted line under the title)
is optional on all of them. `new_page: true` starts the section on a new
page; photos, plans and maps do so by default (`new_page: false` stops it).

### `table`: labelled facts

```json
{
  "type": "table",
  "title": "Property details",
  "rows": [
    { "label": "Structure", "value": "Reinforced concrete, 3 storeys", "ja_label": "構造・工法", "ja": "RC3階建" },
    { "label": "Zoning", "value": "Category 2 low-rise exclusive residential district", "ja_label": "用途地域", "ja": "２種低層" },
    { "label": "Land category", "value": "Not stated", "ja_label": "地目", "note": "The listing shows a dash." }
  ]
}
```

`ja_label` is the listing's label exactly as in `listing.json`; it is how the
build knows the field is covered and is not printed. `ja` is printed small
under the value: use it for the original wording of anything legal or
administrative. `note` is printed small and muted.

### `highlights`: selling points and equipment

```json
{
  "type": "highlights",
  "title": "Property highlights",
  "points": ["Solidly built reinforced-concrete structure.", "The third floor can be used as a two-family residence or rented out."],
  "equipment": ["SECOM security", "Lift", "Underfloor heating"],
  "quote": { "label": "From the agent", "text": "An LDK of 40 jō, a spacious terrace, a designed south garden, parking for three cars." }
}
```

`equipment` and `quote` are optional. `points_title` and `equipment_title`
replace the default column headings.

### `photos`: a grid of photos

```json
{
  "type": "photos",
  "title": "Photos",
  "intro": "Labels and captions are translated from the listing, in the listing's order.",
  "columns": 2,
  "items": [
    { "photo": "p001", "label": "Living room", "caption": "First-floor living-dining room.", "note": "The furniture is computer-generated." },
    { "photo": "p034", "label": "Local guide map", "fit": "contain" }
  ]
}
```

`columns` is 1, 2 (default) or 3. `label` is the listing's category for the
photo; `caption` is the listing's caption; `note` is for a remark of yours or
for sales boilerplate you keep. Photos are cropped to 4:3 unless the image is
portrait or very wide; set `fit` to `contain` to show a whole image (maps,
diagrams, documents) or `cover` to force the crop.

### `plan`: a floor plan or lot plan with its labels

```json
{
  "type": "plan",
  "title": "Lot plan",
  "photo": "p020",
  "caption": "¥488 million, 5LLDDKK + 2S, land area 409.22 m², building area 540.53 m².",
  "labels_title": "Labels on the plan",
  "labels": [
    { "label": "公道 約7.2m", "text": "Public road, about 7.2 m wide (north-west side)" },
    { "label": "敷地面積 409.22㎡（約123.78坪）", "text": "Site area 409.22 m² (about 123.78 tsubo)" }
  ],
  "notes": ["North is to the top right, as the arrow on the plan shows."]
}
```

Open the plan image at full size and transcribe what is printed on it. For a
floor plan, group the labels by floor (`"label": "1F"`). For a lot plan, give
every road with its width and side, every dimension, the north arrow, and
anything drawn on the lot (parking, garden, setback line).

### `maps`: maps made by `brochure maps`

```json
{
  "type": "maps",
  "title": "Location",
  "items": [
    { "map": "aerial", "caption": "The ring marks the position the listing's own map gives, which the listing says is a nearby address and may differ from the lot." },
    { "map": "area", "caption": "Ogikubo Station is to the north-east." }
  ],
  "notes": ["Coordinates from the listing page: 35.69819, 139.61510."]
}
```

Always say where the marker came from and how exact it is. Look at the aerial
image and check the marker sits where the address says before you describe it.

### `cards`: small items with an optional photo

```json
{
  "type": "cards",
  "title": "Neighbourhood",
  "items": [{ "photo": "p021", "title": "OK Store Ogikubo: 484 m", "text": "7 min walk. Open 8:30 to 21:30." }]
}
```

### `text`, `list`, `tags`

```json
{ "type": "text", "title": "From the agent", "paragraphs": ["…"], "quote": true }
{ "type": "list", "title": "SUUMO's standard notes", "items": ["…"], "ordered": true, "two_columns": false }
{ "type": "tags", "title": "Feature tags", "items": ["Parking for 3 or more cars", "Immediate handover"] }
```

### `notes`: translator's notes

```json
{
  "type": "notes",
  "title": "Translator's notes",
  "glossary": [{ "term": "jō / J", "meaning": "A room size in tatami mats. One mat is about 1.62 m²." }],
  "groups": [
    { "title": "Left as written in the source", "items": ["The headline says the bus stop is 2 minutes away; the agent's message says 1 minute."] },
    { "title": "Not stated on the listing", "items": ["Land category, builder, energy performance."] }
  ]
}
```

End every brochure with this section. `glossary` explains each Japanese term
and unit the brochure uses. "Left as written" records contradictions inside
the listing; report them, do not resolve them. "Not stated" lists the fields
the listing leaves blank.
