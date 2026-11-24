"""Check brochure.json and turn it into brochure.html.

brochure.json holds the English content the agent wrote; this module adds no
wording of its own. It refuses to build when a photo is unaccounted for or a
draft placeholder was left untranslated, so an omission is a decision someone
made, not something that slipped.
"""

from __future__ import annotations

import html
import unicodedata
from typing import Any, Dict, Iterator, List, Optional, Tuple

from store import BrochureError, Folder, read_json

DRAFT_PREFIX = "JA: "
SECTION_TYPES = ("highlights", "table", "photos", "plan", "maps", "text", "tags", "cards", "list", "notes")

_CSS = """
:root { --ink:#1b1f1e; --muted:#5f6764; --line:#dfe3e1; --accent:#1f5f4a; --soft:#f4f6f5; }
@page {
  size: A4; margin: 13mm 14mm 15mm 14mm;
  @bottom-left { content: "%(footer)s"; font-family: %(fonts)s; font-size: 7.5pt; color: #5f6764; }
  @bottom-right { content: counter(page) " / " counter(pages); font-family: %(fonts)s; font-size: 7.5pt; color: #5f6764; }
}
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { margin: 0; font-family: %(fonts)s; font-size: 9.6pt; line-height: 1.5; color: var(--ink); }
@media screen { body { max-width: 182mm; margin: 12mm auto; } }
a { color: var(--accent); text-decoration: none; word-break: break-all; }
p { margin: 0 0 2.4mm; }
h1 { font-size: 23pt; line-height: 1.14; letter-spacing: -0.012em; margin: 1.5mm 0 3mm; font-weight: 700; }
h2 { font-size: 14.5pt; line-height: 1.2; margin: 0 0 3.5mm; padding-top: 3.2mm; border-top: 0.55mm solid var(--accent); font-weight: 700; break-after: avoid; }
h3 { font-size: 9.6pt; margin: 4mm 0 1.6mm; color: var(--accent); font-weight: 700; break-after: avoid; }
.eyebrow { font-size: 7.6pt; letter-spacing: 0.15em; text-transform: uppercase; color: var(--accent); font-weight: 700; margin: 0; }
.lead { font-size: 11.6pt; line-height: 1.42; margin: 0 0 1.6mm; }
.tagline, .intro { color: var(--muted); font-size: 8.8pt; }
.hero { margin: 4mm 0 4.5mm; }
.hero img { display: block; width: 100%%; height: 104mm; object-fit: cover; border-radius: 0.7mm; }
.facts { display: grid; grid-template-columns: repeat(3, 1fr); border: 0.25mm solid var(--line); border-radius: 1mm; overflow: hidden; margin-bottom: 4mm; }
.fact { padding: 3.6mm 4.2mm 3.2mm; border-right: 0.25mm solid var(--line); border-bottom: 0.25mm solid var(--line); margin: 0 -0.25mm -0.25mm 0; }
.fact .k { display: block; font-size: 7pt; letter-spacing: 0.14em; text-transform: uppercase; color: var(--muted); margin-bottom: 1.6mm; }
.fact b { display: block; font-size: 12.6pt; line-height: 1.25; }
.fact .n { display: block; font-size: 8pt; color: var(--muted); margin-top: 1.2mm; }
.source { font-size: 7.8pt; color: var(--muted); line-height: 1.5; }
.block { margin-top: 8mm; }
.block.page, .cover + .block { break-before: page; margin-top: 0; }
.grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 5mm 6mm; }
.grid.c3 { grid-template-columns: repeat(3, 1fr); gap: 5.5mm 5mm; }
.grid.c1 { grid-template-columns: 1fr; }
figure { margin: 0; break-inside: avoid; }
.frame { aspect-ratio: 16 / 10; background: var(--soft); border-radius: 0.7mm; overflow: hidden; }
.frame img { display: block; width: 100%%; height: 100%%; object-fit: cover; }
.contain .frame img { object-fit: scale-down; }
.grid.c1 .frame { aspect-ratio: 16 / 10; }
.grid.c3 .frame { aspect-ratio: 4 / 3; }
figcaption { margin-top: 1.8mm; font-size: 8.4pt; line-height: 1.42; }
figcaption b { display: block; color: var(--accent); }
figcaption i { display: block; color: var(--muted); }
.plan .sheet { border: 0.25mm solid var(--line); border-radius: 0.7mm; padding: 3mm; text-align: center; }
.plan .sheet img { max-width: 100%%; max-height: 132mm; object-fit: contain; }
table { width: 100%%; border-collapse: collapse; }
tr { break-inside: avoid; }
th, td { text-align: left; vertical-align: top; padding: 2.1mm 0; border-bottom: 0.25mm solid var(--line); }
th { width: 31%%; padding-right: 4mm; font-weight: 600; }
.ja { display: block; color: var(--muted); font-size: 7.8pt; line-height: 1.4; margin-top: 0.5mm; }
.rownote { display: block; color: var(--muted); font-size: 8.2pt; }
ul, ol { margin: 0 0 2mm; padding-left: 4.6mm; }
ol { padding-left: 7mm; }
li { margin-bottom: 1.1mm; break-inside: avoid; }
.two { columns: 2; column-gap: 8mm; }
.three { columns: 3; column-gap: 7mm; }
.split { display: grid; grid-template-columns: 1.15fr 1fr; gap: 0 9mm; }
.grid.c1 > .map { width: 140mm; margin: 0 auto; }
blockquote { margin: 3.5mm 0 0; padding: 2.6mm 4mm; border-left: 0.7mm solid var(--accent); background: var(--soft); break-inside: avoid; }
blockquote b { display: block; font-size: 7.6pt; letter-spacing: 0.12em; text-transform: uppercase; color: var(--accent); margin-bottom: 1mm; }
.tags span { display: inline-block; border: 0.25mm solid var(--line); border-radius: 3mm; padding: 0.5mm 2.6mm; margin: 0 1.4mm 1.6mm 0; font-size: 8.4pt; }
.card b { display: block; margin: 1.8mm 0 0.6mm; font-size: 8.8pt; }
.card { font-size: 8.4pt; line-height: 1.45; break-inside: avoid; }
.map .tiles { position: relative; display: grid; line-height: 0; border-radius: 0.7mm; overflow: hidden; }
.map .tiles img { display: block; width: 100%%; }
.map .pin { position: absolute; width: 9mm; height: 9mm; margin: -4.5mm 0 0 -4.5mm; border: 0.8mm solid #e11d48; border-radius: 50%%; box-shadow: 0 0 0 0.35mm #fff, inset 0 0 0 0.35mm #fff; }
.map .bar { position: absolute; left: 3mm; bottom: 3mm; height: 4.6mm; border: 0.45mm solid #111; border-top: 0; background: rgba(255,255,255,0.78); color: #111; font-size: 7pt; line-height: 4mm; text-align: center; }
.credit { font-size: 7.2pt; color: var(--muted); margin-top: 1mm; }
"""

_FONTS = '-apple-system, "Helvetica Neue", "Hiragino Sans", "Noto Sans CJK JP", "Noto Sans JP", "Yu Gothic", Arial, sans-serif'


def _e(value: Any) -> str:
    return html.escape("" if value is None else str(value)).replace("\n", "<br>")


def _css_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def _strings(node: Any, path: str = "") -> Iterator[Tuple[str, str]]:
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from _strings(item, "%s[%d]" % (path, index))
    elif isinstance(node, dict):
        for key, item in node.items():
            yield from _strings(item, "%s.%s" % (path, key) if path else key)


def untranslated(content: Any) -> List[Tuple[str, str]]:
    """(JSON path, text) of every string still carrying the draft marker."""
    return [(path, value) for path, value in _strings(content) if value.startswith(DRAFT_PREFIX)]


def _photo_refs(content: Dict[str, Any]) -> List[Tuple[str, str]]:
    """(photo id, where it is used) for every photo the content places."""
    refs = []
    if content.get("hero_photo"):
        refs.append((content["hero_photo"], "hero_photo"))
    for index, section in enumerate(content.get("sections") or []):
        where = "sections[%d]" % index
        if section.get("type") == "plan" and section.get("photo"):
            refs.append((section["photo"], where))
        for item in section.get("items") or []:
            if isinstance(item, dict) and item.get("photo"):
                refs.append((item["photo"], where))
    return refs


class Checked:
    """brochure.json after validation, with the photos and maps it refers to."""

    def __init__(self, content: Dict[str, Any], photos: Dict[str, Dict[str, Any]], maps: Dict[str, Dict[str, Any]], warnings: List[str]) -> None:
        self.content = content
        self.photos = photos
        self.maps = maps
        self.warnings = warnings


def check(folder: Folder) -> Checked:
    """Validate brochure.json against the listing's photos, maps and fields. Raises BrochureError listing every problem."""
    content = folder.require(folder.content, "write it from the draft (`brochure draft`) and listing.json")
    listing = read_json(folder.listing) or {"pairs": [], "photos": []}
    photos = {p["id"]: p for p in (read_json(folder.photos) or {"photos": []})["photos"]}
    maps = {m["id"]: m for m in (read_json(folder.maps) or {"maps": []})["maps"]}
    errors: List[str] = []
    warnings: List[str] = []

    for key in ("title", "short_name", "eyebrow"):
        if not isinstance(content.get(key), str) or not content[key].strip():
            errors.append("'%s' is required" % key)
    source = content.get("source") or {}
    for key in ("site", "url", "translated_on"):
        if not source.get(key):
            errors.append("'source.%s' is required" % key)
    facts = content.get("key_facts")
    if not isinstance(facts, list) or not 3 <= len(facts) <= 9:
        errors.append("'key_facts' needs 3 to 9 entries of {label, value, note}")
    else:
        for index, fact in enumerate(facts):
            if not fact.get("label") or not fact.get("value"):
                errors.append("key_facts[%d] needs 'label' and 'value'" % index)
    sections = content.get("sections")
    if not isinstance(sections, list) or not sections:
        errors.append("'sections' needs at least one section")
        sections = []

    required = {
        "highlights": ("points",), "table": ("rows",), "photos": ("items",), "plan": ("photo",), "maps": ("items",),
        "text": ("paragraphs",), "tags": ("items",), "cards": ("items",), "list": ("items",), "notes": (),
    }
    for index, section in enumerate(sections):
        where = "sections[%d]" % index
        kind = section.get("type")
        if kind not in SECTION_TYPES:
            errors.append("%s.type %r is not one of %s" % (where, kind, ", ".join(SECTION_TYPES)))
            continue
        if not section.get("title"):
            errors.append("%s (%s) needs a 'title'" % (where, kind))
        for key in required[kind]:
            if not section.get(key):
                errors.append("%s (%s) needs '%s'" % (where, kind, key))
        if kind == "table":
            for r, row in enumerate(section.get("rows") or []):
                if not row.get("label") or row.get("value") in (None, ""):
                    errors.append("%s.rows[%d] needs 'label' and 'value'" % (where, r))
        if kind == "maps":
            for item in section.get("items") or []:
                if item.get("map") not in maps:
                    errors.append("%s refers to map %r, which `brochure maps` has not made" % (where, item.get("map")))
        if kind == "notes" and not (section.get("glossary") or section.get("groups")):
            errors.append("%s (notes) needs 'glossary' or 'groups'" % where)

    for path, value in untranslated(content):
        errors.append("%s is still untranslated draft text: %s" % (path, value[:60]))

    used = set()
    for photo_id, where in _photo_refs(content):
        record = photos.get(photo_id)
        if record is None:
            errors.append("%s uses photo %r, which is not in photos.json" % (where, photo_id))
        elif record.get("status") == "duplicate":
            errors.append("%s uses %s, a duplicate of %s; use %s" % (where, photo_id, record["duplicate_of"], record["duplicate_of"]))
        elif record.get("status") != "ok":
            errors.append("%s uses %s, which was not downloaded (%s)" % (where, photo_id, "; ".join(record.get("errors") or [])[:120]))
        used.add(photo_id)
    omitted = {}
    for entry in content.get("omitted_photos") or []:
        if not entry.get("photo") or not entry.get("reason"):
            errors.append("each omitted_photos entry needs 'photo' and 'reason'")
        else:
            omitted[entry["photo"]] = entry["reason"]
    for photo_id, record in sorted(photos.items()):
        if record.get("status") == "duplicate" or photo_id in used or photo_id in omitted:
            continue
        state = "downloaded" if record.get("status") == "ok" else "not downloaded"
        errors.append("photo %s (%s, %s) is neither placed nor listed in omitted_photos with a reason" % (photo_id, record.get("category") or "no category", state))

    def fold(label: Any) -> str:
        # 完成時期（築年月） and 完成時期(築年月) are one label written two ways.
        return unicodedata.normalize("NFKC", str(label)).replace(" ", "")

    covered = {fold(label) for label in content.get("ignored_labels") or []}
    for section in sections:
        for row in section.get("rows") or []:
            named = row.get("ja_label") or []
            covered.update(fold(label) for label in ([named] if isinstance(named, str) else named))
    missing = []
    for pair in listing.get("pairs") or []:
        if fold(pair["label"]) not in covered and pair["label"] not in missing:
            missing.append(pair["label"])
    if missing:
        warnings.append(
            "%d listing fields are not named by any row's ja_label and are not in ignored_labels: %s"
            % (len(missing), "、".join(missing[:40]) + (" …" if len(missing) > 40 else ""))
        )

    if errors:
        raise BrochureError("brochure.json has %d problem(s):\n  - %s" % (len(errors), "\n  - ".join(errors)))
    return Checked(content, photos, maps, warnings)


# ---------------------------------------------------------------- HTML


def _img(checked: Checked, photo_id: str) -> str:
    return '<img src="%s" alt="">' % _e(checked.photos[photo_id]["file"])


def _fit(checked: Checked, item: Dict[str, Any]) -> str:
    if item.get("fit") in ("cover", "contain"):
        return item["fit"]
    record = checked.photos[item["photo"]]
    width, height = record.get("width") or 4, record.get("height") or 3
    # Portrait and very wide images lose too much to a 4:3 crop.
    return "cover" if 1.05 <= width / height <= 1.9 else "contain"


def _figure(checked: Checked, item: Dict[str, Any]) -> str:
    caption = ""
    if item.get("label") or item.get("caption") or item.get("note"):
        caption = "<figcaption>%s%s%s</figcaption>" % (
            "<b>%s</b>" % _e(item["label"]) if item.get("label") else "",
            _e(item.get("caption") or ""),
            "<i>%s</i>" % _e(item["note"]) if item.get("note") else "",
        )
    return '<figure class="%s"><div class="frame">%s</div>%s</figure>' % (_fit(checked, item), _img(checked, item["photo"]), caption)


def _rows(rows: List[Dict[str, Any]]) -> str:
    out = []
    for row in rows:
        extra = ""
        if row.get("note"):
            extra += '<span class="rownote">%s</span>' % _e(row["note"])
        if row.get("ja"):
            extra += '<span class="ja" lang="ja">%s</span>' % _e(row["ja"])
        out.append("<tr><th>%s</th><td>%s%s</td></tr>" % (_e(row["label"]), _e(row["value"]), extra))
    return "<table>%s</table>" % "".join(out)


def _list(items: List[str], ordered: bool = False, css: str = "") -> str:
    tag = "ol" if ordered else "ul"
    return "<%s%s>%s</%s>" % (tag, ' class="%s"' % css if css else "", "".join("<li>%s</li>" % _e(i) for i in items), tag)


def _map(checked: Checked, item: Dict[str, Any]) -> str:
    spec = checked.maps[item["map"]]
    tiles = "".join('<img src="%s" alt="">' % _e(t) for t in spec["tiles"])
    bar_width = 100.0 * spec["scale_bar_m"] / spec["width_m"]
    bar_text = "%d m" % spec["scale_bar_m"] if spec["scale_bar_m"] < 1000 else "%g km" % (spec["scale_bar_m"] / 1000)
    return (
        '<figure class="map"><div class="tiles" style="grid-template-columns:repeat(%d,1fr)">%s'
        '<span class="pin" style="left:%.2f%%;top:%.2f%%"></span><span class="bar" style="width:%.2f%%">%s</span></div>'
        "<figcaption><b>%s</b>%s</figcaption><p class=\"credit\">%s</p></figure>"
    ) % (
        spec["columns"], tiles, 100 * spec["marker"]["x"], 100 * spec["marker"]["y"], bar_width, _e(bar_text),
        _e(item.get("title") or spec["title"]), _e(item.get("caption") or ""), _e(spec["attribution"]),
    )


def _section(checked: Checked, section: Dict[str, Any]) -> str:
    kind = section["type"]
    parts = ["<h2>%s</h2>" % _e(section["title"])]
    if section.get("intro"):
        parts.append('<p class="intro">%s</p>' % _e(section["intro"]))
    if kind == "highlights":
        equipment = section.get("equipment") or []
        points_title = "<h3>%s</h3>" % _e(section.get("points_title") or "Points")
        equipment_title = "<h3>%s</h3>" % _e(section.get("equipment_title") or "Equipment")
        if not equipment:
            parts.append(_list(section["points"]))
        elif len(equipment) <= 8:
            parts.append('<div class="split"><div>%s%s</div><div>%s%s</div></div>' % (
                points_title, _list(section["points"]), equipment_title, _list(equipment)))
        else:
            # A long equipment list beside a short list of points leaves half the page empty.
            parts.append(points_title + _list(section["points"]) + equipment_title + _list(equipment, css="three"))
        quote = section.get("quote")
        if quote:
            parts.append("<blockquote><b>%s</b>%s</blockquote>" % (_e(quote.get("label") or "From the agent"), _e(quote.get("text"))))
    elif kind == "table":
        parts.append(_rows(section["rows"]))
    elif kind == "photos":
        columns = section.get("columns") or 2
        parts.append('<div class="grid c%d">%s</div>' % (columns, "".join(_figure(checked, i) for i in section["items"])))
    elif kind == "plan":
        parts.append('<figure class="plan"><div class="sheet">%s</div>%s</figure>' % (
            _img(checked, section["photo"]),
            "<figcaption>%s</figcaption>" % _e(section["caption"]) if section.get("caption") else "",
        ))
        if section.get("labels"):
            parts.append("<h3>%s</h3>" % _e(section.get("labels_title") or "Labels on the plan"))
            parts.append(_rows([{"label": l["label"], "value": l["text"]} for l in section["labels"]]))
        if section.get("notes"):
            parts.append(_list(section["notes"]))
    elif kind == "maps":
        items = section["items"]
        columns = section.get("columns") or (1 if len(items) == 1 else 2)
        parts.append('<div class="grid c%d">%s</div>' % (columns, "".join(_map(checked, i) for i in items)))
        if section.get("notes"):
            parts.append(_list(section["notes"]))
    elif kind == "text":
        body = "".join("<p>%s</p>" % _e(p) for p in section["paragraphs"])
        parts.append("<blockquote>%s</blockquote>" % body if section.get("quote") else body)
    elif kind == "tags":
        parts.append('<div class="tags">%s</div>' % "".join("<span>%s</span>" % _e(i) for i in section["items"]))
    elif kind == "cards":
        cards = []
        for item in section["items"]:
            picture = ""
            if item.get("photo"):
                picture = '<div class="%s"><div class="frame">%s</div></div>' % (_fit(checked, item), _img(checked, item["photo"]))
            cards.append('<div class="card">%s<b>%s</b>%s</div>' % (picture, _e(item.get("title")), _e(item.get("text") or "")))
        parts.append('<div class="grid c3">%s</div>' % "".join(cards))
    elif kind == "list":
        parts.append(_list(section["items"], bool(section.get("ordered")), "two" if section.get("two_columns") else ""))
    elif kind == "notes":
        if section.get("glossary"):
            parts.append(_rows([{"label": g["term"], "value": g["meaning"]} for g in section["glossary"]]))
        for group in section.get("groups") or []:
            parts.append("<h3>%s</h3>%s" % (_e(group["title"]), _list(group["items"])))
    css = "block" + (" page" if section.get("new_page") else "")
    return '<section class="%s">%s</section>' % (css, "".join(parts))


def render(checked: Checked) -> str:
    content = checked.content
    source = content["source"]
    footer = " · ".join(x for x in (content["short_name"], source["site"] + (" listing " + str(source["listing_id"]) if source.get("listing_id") else ""), "English translation") if x)
    css = _CSS % {"footer": _css_string(footer), "fonts": _FONTS}
    hero = '<figure class="hero">%s</figure>' % _img(checked, content["hero_photo"]) if content.get("hero_photo") else ""
    facts = "".join(
        '<div class="fact"><span class="k">%s</span><b>%s</b>%s</div>'
        % (_e(f["label"]), _e(f["value"]), '<span class="n">%s</span>' % _e(f["note"]) if f.get("note") else "")
        for f in content["key_facts"]
    )
    dates = []
    if source.get("information_date"):
        dates.append("Information date on the listing: %s." % source["information_date"])
    if source.get("next_update"):
        dates.append("Next scheduled update: %s." % source["next_update"])
    dates.append("Translated %s from the Japanese listing; photos, plans and listing text are the listing's own." % source["translated_on"])
    cover = (
        '<header class="cover"><p class="eyebrow">%s</p><h1>%s</h1>%s%s%s<div class="facts">%s</div>%s'
        '<p class="source">Source: <a href="%s">%s</a><br>%s</p></header>'
    ) % (
        _e(content["eyebrow"]),
        _e(content["title"]),
        '<p class="lead">%s</p>' % _e(content["subtitle"]) if content.get("subtitle") else "",
        '<p class="tagline">%s</p>' % _e(content["tagline"]) if content.get("tagline") else "",
        hero,
        facts,
        "<p>%s</p>" % _e(content["summary"]) if content.get("summary") else "",
        _e(source["url"]),
        _e(source["url"]),
        _e(" ".join(dates)),
    )
    body = "".join(_section(checked, s) for s in content["sections"])
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>%s</title><style>%s</style></head>'
        "<body>%s%s</body></html>\n"
    ) % (_e(content["short_name"] + ": " + source["site"] + " listing (English)"), css, cover, body)


def build(folder: Folder) -> Checked:
    checked = check(folder)
    folder.html.write_text(render(checked), encoding="utf-8")
    return checked


def unplaced(folder: Folder) -> Optional[List[str]]:
    """Photo ids the content does not account for yet, or None when there is no content file."""
    content = read_json(folder.content)
    if content is None:
        return None
    photos = (read_json(folder.photos) or {"photos": []})["photos"]
    done = {ref for ref, _where in _photo_refs(content)} | {e.get("photo") for e in content.get("omitted_photos") or []}
    return [p["id"] for p in photos if p.get("status") != "duplicate" and p["id"] not in done]
