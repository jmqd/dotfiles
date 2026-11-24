# The criteria profile

`<home>/profile.json` holds what the buyer wants and how a run behaves.
`jpsearch init` creates it from `default-profile.json`. Edit it when the
brief changes; every later run uses it. A malformed profile stops every
command with the field at fault.

## How a property is judged

Listings of one house are grouped first, then the house is judged once. Each
criterion gives one of four results, and the worst decides the status:

| Status | Meaning |
|---|---|
| `match` | Every criterion is met, from what the listing states. |
| `near` | Nothing fails, but one or more points need the buyer's eye: an area just under its minimum, a mixed structure, a flag held for review, or listings that disagree. |
| `unverified` | Nothing fails, but a criterion is unstated (most often the structure) or the address is too vague to pick a zone. |
| `rejected` | A criterion fails. The listing and the reason go to `rejected.csv`. |

A rejected house is never shown as a candidate, and an unknown never counts
as a pass.

## Fields

| Field | Default | Meaning |
|---|---|---|
| `name` | | A label for the report. |
| `listing_types` | `["used_house"]` | Kinds of listing to search. Only `used_house` has automated searches. |
| `building_m2_min` | `250` | Smallest total floor area, in m². |
| `structures` | `["RC", "SRC"]` | Accepted structures: `RC` reinforced concrete, `SRC` steel-reinforced concrete, `S` steel frame, `W` wood, `CB` concrete block. |
| `mixed_structure` | `"review"` | A house that is part accepted structure and part not (木造一部RC): `review` lists it as `near`, `accept` passes it, `reject` rejects it. A mix of accepted structures only (SRC with RC) always passes. Outbuildings are ignored. |
| `near_miss_percent` | `10` | How far under a minimum still counts as `near`. With 10, a 230 m² house or a 950 m² lot is a near miss. The searches fetch down to this band. |
| `zones` | see below | Minimum lot size by area. |
| `price_jpy_max` | `null` | Highest price in yen, or `null` for no limit. A listing with no price is then `unverified`. |
| `built_year_min` | `null` | Earliest year built, or `null`. Houses built before June 1981, under the old seismic code, carry a flag either way. |
| `review_flags` | `["tenant_occupied", "not_a_dwelling"]` | Flags that turn a match into `near`, with the reason shown. |
| `reject_flags` | `[]` | Flags that reject a house. `["leasehold"]` keeps freehold only. |
| `areas` | `"all"` | Prefectures to search: `"all"`, or a list such as `["東京都", "長野県"]` (English names work: `"Nagano"`). A house found elsewhere, on a site that is searched nationwide, is rejected. |
| `sources` | `"all"` | Source ids to search, or `"all"`. |
| `exclude_sources` | `[]` | Source ids to leave out. |
| `request_delay_seconds` | `3` | Pause between pages on one site. At least 2. A site's own Crawl-delay is honoured when longer. |
| `detail_cache_days` | `30` | How long a detail page read in an earlier run is trusted without reading it again. The price is always the one on today's result card. |
| `max_detail_pages` | `400` | Most detail pages one run reads, those hinting at concrete and the largest houses first. The rest are deferred and reported: run again or raise it. |

## Zones

A zone sets the minimum lot size for an area. Zones are tried in order and
the first that covers the address applies. The last zone must cover
everything.

```json
"zones": [
  { "id": "tokyo-23", "label": "Central Tokyo (23 wards)", "prefecture": "東京都", "municipality_suffix": "区", "land_m2_min": 190 },
  { "id": "elsewhere", "label": "Outside central Tokyo", "land_m2_min": 1000 }
]
```

| Key | Meaning |
|---|---|
| `id`, `label` | Name in the data and in the report. |
| `land_m2_min` | Smallest lot, in m². |
| `prefecture` | Limits the zone to one prefecture. |
| `municipality_suffix` | Limits it to municipalities ending so. `"区"` in 東京都 means the 23 wards. |
| `municipalities` | Limits it to named municipalities, such as `["軽井沢町", "鎌倉市"]`. |

"Central Tokyo" is the 23 wards by default. To use the central wards only,
replace the suffix with `"municipalities": ["千代田区", "中央区", "港区", "新宿区", "渋谷区", "文京区", "目黒区", "品川区"]`.

A listing whose address does not reach the municipality cannot be given a
zone. It is `unverified` unless its lot is under every zone's minimum.

## Flags

Flags come from the listing's own words, and two from its facts (the layout
and the build date, taken from what most listings of the property state).
Every flag is shown on the property's card. A flag changes the status only
when the profile names it in `review_flags` or `reject_flags`.

| Flag | Raised by |
|---|---|
| `leasehold` | 借地, 地上権, 賃借権 in the tenure or remarks |
| `no_rebuild` | 再建築不可 |
| `urbanisation_control` | 市街化調整区域 |
| `setback` | セットバック, 要後退 |
| `notice` | 告知事項, 心理的瑕疵 |
| `tenant_occupied` | 賃貸中, オーナーチェンジ: sold with a tenant in place |
| `not_a_dwelling` | The title or type names the property as a warehouse, factory, office, company retreat, dormitory, inn, hotel, clinic, office building, apartment block or whole block (一棟); or the opening of its page introduces it as one (大型保養所です); or every listing of it that gives a layout gives one room, for 150 m² or more |
| `under_negotiation` | 商談中, 申込あり |
| `unregistered_part` | 未登記 |
| `slope_or_retaining_wall` | がけ, 擁壁, 急傾斜 |
| `hazard_zone` | 土砂災害警戒区域, 浸水想定 and the like |
| `farmland` | 農地, 農振 |
| `natural_park` | 国立公園, 国定公園 |
| `non_conforming` | 既存不適格, 違反建築 |
| `pre_1981_seismic_code` | Built before June 1981 |

## Examples

A price ceiling, and nothing built before 1982:

```json
"price_jpy_max": 500000000,
"built_year_min": 1982
```

Mountain resort prefectures only, with a larger lot in Karuizawa:

```json
"areas": ["長野県", "山梨県", "群馬県"],
"zones": [
  { "id": "karuizawa", "label": "Karuizawa", "prefecture": "長野県", "municipalities": ["軽井沢町"], "land_m2_min": 1500 },
  { "id": "elsewhere", "label": "Elsewhere", "land_m2_min": 1000 }
]
```

A small first run, to see that everything works:

```json
"areas": ["東京都"],
"sources": ["suumo"],
"max_detail_pages": 40
```
