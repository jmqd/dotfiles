"""Write a run's results: report.html, report.md, candidates.json/.csv, rejected.csv."""

from __future__ import annotations

import csv
import html
from typing import Any, Dict, List, Optional

import criteria
import text
from criteria import Profile
from workspace import Workspace, write_json

CHANGE_LABELS = {
    "new": "New",
    "relisted": "Relisted",
    "price_down": "Price cut",
    "price_up": "Price raised",
    "seen": "",
}

SECTIONS = (
    (criteria.MATCH, "Matches", "Every criterion is met and confirmed from the listing."),
    (criteria.NEAR_MISS, "Near misses and points to confirm", "Just under a threshold, or one point stands between the listing and a match."),
    (criteria.UNVERIFIED, "Unverified", "Nothing rules these out, but a criterion is unstated or the listing page could not be read."),
)


def yen(value: Optional[int]) -> str:
    return "¥{:,}".format(value) if value is not None else "price on request"


def oku_man(value: Optional[int]) -> str:
    """488000000 -> 4億8,800万円."""
    if value is None:
        return ""
    oku, rest = divmod(value, 100_000_000)
    man = rest // 10_000
    parts = ("%d億" % oku if oku else "") + ("{:,}万".format(man) if man else "")
    return (parts or "0") + "円"


def area(m2: Optional[float], variants: Optional[List[float]] = None) -> str:
    if m2 is None:
        return "not stated"
    stated = "{:,.2f} m² ({:,.1f} tsubo)".format(m2, text.to_tsubo(m2))
    others = [v for v in variants or [] if v != m2]
    if others:
        # Agents listing one house sometimes quote different figures; show them rather than pick silently.
        stated += "; other listings say " + ", ".join("{:,.2f}".format(v) for v in others)
    return stated


def structure_label(prop: Dict[str, Any]) -> str:
    kind = prop.get("structure")
    if kind is None:
        return "not stated" + (" (text mentions concrete)" if prop.get("concrete_hint") else "")
    if prop.get("structure_variants"):
        return "listings disagree: " + " / ".join(v["text"] for v in prop["structure_variants"])
    if kind == text.MIXED:
        name = "mixed: " + " + ".join(criteria.STRUCTURE_NAMES.get(p, p) for p in prop.get("structure_parts") or [])
    else:
        name = criteria.STRUCTURE_NAMES.get(kind, kind)
    floors = []
    if prop.get("floors"):
        floors.append("%d storey%s" % (prop["floors"], "" if prop["floors"] == 1 else "s"))
    if prop.get("basement"):
        floors.append("%d basement" % prop["basement"])
    return name + (", " + " + ".join(floors) if floors else "")


def built_label(prop: Dict[str, Any], run_year: int) -> str:
    year = prop.get("built_year")
    if year is None:
        return "not stated"
    month = "-%02d" % prop["built_month"] if prop.get("built_month") else ""
    approx = "about " if prop.get("built_approximate") else ""
    stated = "%s%d%s (%d years old)" % (approx, year, month, max(0, run_year - year))
    others = [v for v in prop.get("built_year_variants") or [] if v != year]
    if others:
        stated += "; other listings say " + ", ".join(str(v) for v in others)
    return stated


def location_label(prop: Dict[str, Any]) -> str:
    romaji = text.PREF_ROMAJI.get(prop.get("prefecture") or "", "")
    address = prop.get("address") or "address not stated"
    return "%s (%s)" % (address, romaji) if romaji else address


def _sort_key(prop: Dict[str, Any]) -> tuple:
    return (
        0 if prop.get("mark") == "shortlist" else 1,
        0 if prop.get("change") in ("new", "relisted", "price_down") else 1,
        -(prop.get("building_m2") or 0.0),
        prop["id"],
    )


# ---------------------------------------------------------------- HTML

_CSS = """
:root { --ink:#1c1f1e; --muted:#5d6562; --line:#dfe3e1; --accent:#1f5f4a; --soft:#f4f6f5; --warn:#8a5a00; --bad:#9b2c2c; }
* { box-sizing: border-box; }
body { margin:0; font:15px/1.5 -apple-system,"Helvetica Neue","Hiragino Sans","Noto Sans JP","Yu Gothic",sans-serif; color:var(--ink); background:#fff; }
main { max-width:1040px; margin:0 auto; padding:32px 24px 64px; }
h1 { font-size:28px; margin:0 0 4px; letter-spacing:-.01em; }
h2 { font-size:20px; margin:40px 0 4px; padding-top:16px; border-top:2px solid var(--accent); }
.eyebrow { font-size:12px; letter-spacing:.14em; text-transform:uppercase; color:var(--accent); font-weight:600; }
.lede, .sub { color:var(--muted); margin:0 0 16px; }
.stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(130px,1fr)); gap:1px; background:var(--line); border:1px solid var(--line); border-radius:6px; overflow:hidden; margin:20px 0; }
.stats div { background:#fff; padding:12px 14px; }
.stats b { display:block; font-size:22px; }
.stats span { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; }
.card { display:grid; grid-template-columns:240px 1fr; gap:18px; padding:18px 0; border-bottom:1px solid var(--line); break-inside:avoid; }
.card img { width:240px; height:180px; object-fit:cover; border-radius:4px; background:var(--soft); }
.card .noimg { width:240px; height:180px; border-radius:4px; background:var(--soft); display:flex; align-items:center; justify-content:center; color:var(--muted); font-size:12px; }
.card h3 { margin:0 0 2px; font-size:16px; }
.card .price { font-size:20px; font-weight:650; }
.card .price small { font-size:13px; font-weight:400; color:var(--muted); }
.facts { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:2px 18px; margin:8px 0; font-size:14px; }
.facts dt { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.06em; }
.facts dd { margin:0 0 4px; }
.chips { margin:6px 0; }
.chip { display:inline-block; font-size:12px; padding:1px 8px; border-radius:10px; border:1px solid var(--line); margin:0 4px 4px 0; }
.chip.change { background:var(--accent); color:#fff; border-color:var(--accent); }
.chip.flag { color:var(--warn); border-color:#e6d3a8; background:#fdf8ec; }
.chip.mark { color:var(--accent); border-color:var(--accent); }
.why { font-size:13px; color:var(--warn); margin:4px 0; }
.note { font-size:14px; background:var(--soft); padding:6px 10px; border-left:3px solid var(--accent); margin:6px 0; }
.links { font-size:13px; }
.links a { color:var(--accent); }
.id { font:12px ui-monospace,Menlo,monospace; color:var(--muted); }
table { border-collapse:collapse; width:100%; font-size:13px; margin:10px 0; }
th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
th { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); }
.ok { color:var(--accent); } .partial { color:var(--warn); } .failed { color:var(--bad); }
@media print { main { padding:0; } .card { grid-template-columns:180px 1fr; } .card img, .card .noimg { width:180px; height:135px; } }
"""


def _e(value: Any) -> str:
    return html.escape("" if value is None else str(value))


def _card(prop: Dict[str, Any], run_year: int) -> str:
    chips = []
    if prop.get("mark"):
        chips.append('<span class="chip mark">%s</span>' % _e(prop["mark"].capitalize()))
    change = CHANGE_LABELS.get(prop.get("change") or "", "")
    if change:
        extra = ""
        if prop.get("previous_price_jpy"):
            extra = " from " + yen(prop["previous_price_jpy"])
        chips.append('<span class="chip change">%s%s</span>' % (_e(change), _e(extra)))
    for flag in prop.get("flags") or []:
        chips.append('<span class="chip flag">%s</span>' % _e(criteria.FLAGS.get(flag, flag)))
    price = yen(prop.get("price_jpy"))
    if prop.get("price_max_jpy"):
        price += " to " + yen(prop["price_max_jpy"])
    image = prop.get("image")
    picture = (
        '<img src="%s" alt="" loading="lazy" referrerpolicy="no-referrer">' % _e(image)
        if image
        else '<div class="noimg">no photo captured</div>'
    )
    facts = [
        ("Land", area(prop.get("land_m2"), prop.get("land_m2_variants"))),
        ("Building", area(prop.get("building_m2"), prop.get("building_m2_variants"))),
        ("Structure", structure_label(prop)),
        ("Built", built_label(prop, run_year)),
        ("Layout", prop.get("layout") or "not stated"),
        ("Tenure", prop.get("land_right") or "not stated"),
        ("Location", location_label(prop)),
        ("Access", prop.get("access") or "not stated"),
    ]
    optional = (
        ("Zoning", prop.get("zoning")),
        ("Coverage / floor-area ratio", " / ".join(x for x in (prop.get("coverage_far"), prop.get("far")) if x)),
        ("Road", prop.get("road")),
        ("Services", " · ".join(x for x in (prop.get("water"), prop.get("sewer"), prop.get("gas")) if x)),
        ("Hot spring", prop.get("hot_spring")),
        ("Management fee", prop.get("management_fee")),
        ("Renovation", prop.get("renovation")),
    )
    facts += [(label, value) for label, value in optional if value]
    fact_html = "".join("<div><dt>%s</dt><dd>%s</dd></div>" % (_e(k), _e(v)) for k, v in facts)
    why = "; ".join(prop.get("open_points") or [])
    links = " · ".join(
        '<a href="%s">%s</a>%s'
        % (_e(l["url"]), _e(l["source"]), " (%s)" % _e(l["agent"]) if l.get("agent") else "")
        for l in prop.get("listings") or []
    )
    return (
        '<article class="card" id="%s">%s<div>'
        '<div class="price">%s <small>%s</small></div>'
        "<h3>%s</h3>"
        '<div class="chips">%s</div>%s%s'
        '<dl class="facts">%s</dl>'
        '<div class="links">%s</div>'
        '<div class="id">%s · first seen %s · %d listing%s</div>'
        "</div></article>"
    ) % (
        _e(prop["id"]),
        picture,
        _e(price),
        _e(oku_man(prop.get("price_jpy"))),
        _e(prop.get("title") or prop.get("address") or "(untitled listing)"),
        "".join(chips),
        '<div class="why">Open point: %s</div>' % _e(why) if why else "",
        '<div class="note">%s</div>' % _e(prop["note"]) if prop.get("note") else "",
        fact_html,
        links,
        _e(prop["id"]),
        _e(prop.get("first_seen")),
        len(prop.get("listings") or []),
        "" if len(prop.get("listings") or []) == 1 else "s",
    )


def _criteria_summary(profile: Profile) -> str:
    wanted = ", ".join(criteria.STRUCTURE_NAMES.get(s, s) for s in profile.structures)
    zones = "; ".join("%s: lot ≥ %g m²" % (z.label, z.land_m2_min) for z in profile.zones)
    parts = ["structure: %s" % wanted, "building ≥ %g m²" % profile.building_m2_min, zones]
    if profile.price_jpy_max:
        parts.append("price ≤ %s" % yen(profile.price_jpy_max))
    if profile.built_year_min:
        parts.append("built %d or later" % profile.built_year_min)
    parts.append("near-miss band %g%%" % profile.near_miss_percent)
    for verb, flags in (("held for review", profile.review_flags), ("rejected", profile.reject_flags)):
        if flags:
            parts.append("%s: %s" % (verb, ", ".join(criteria.FLAGS[f].lower() for f in flags)))
    return " · ".join(parts)


def coverage_note(row: Dict[str, Any]) -> str:
    """What a reader must know about a source's run, in one line: what failed and how much was left unread."""
    notes = list(row["problems"])
    for count, wording in (
        (row["pages_unread"], "%d search page%s not fetched yet"),
        (row["details_failed"], "%d detail page%s could not be read"),
        (row["details_gone"], "%d listing page%s no longer available"),
        (row["details_deferred"], "%d detail page%s left for a later run (raise max_detail_pages or run again)"),
        (row["details_unread"], "%d detail page%s not fetched yet"),
    ):
        if count:
            notes.append(wording % (count, "" if count == 1 else "s"))
    if row["truncated"]:
        notes.append("page limit reached on %d search(es)" % len(row["truncated"]))
    return "; ".join(notes)


def _is_manual(row: Dict[str, Any]) -> bool:
    return row["outcome"] == "manual"


def _coverage_table(rows: List[Dict[str, Any]]) -> str:
    """What each source that was searched, or should have been, yielded."""
    body = []
    for row in rows:
        css = {"searched": "ok", "browsed by hand": "ok", "partial": "partial", "failed": "failed", "incomplete": "failed"}.get(row["outcome"], "")
        body.append(
            "<tr><td><a href=\"%s\">%s</a></td><td>%s</td><td class=\"%s\">%s</td><td>%d</td><td>%d</td><td>%d</td><td>%s</td></tr>"
            % (_e(row["home"]), _e(row["name"]), _e(row["kind"]), css, _e(row["outcome"]), row["pages"], row["cards"], row["details"], _e(coverage_note(row)))
        )
    return (
        "<table><thead><tr><th>Source</th><th>Kind</th><th>Outcome</th><th>Pages</th><th>Cards</th>"
        "<th>Detail pages</th><th>Notes</th></tr></thead><tbody>%s</tbody></table>" % "".join(body)
    )


def _manual_table(rows: List[Dict[str, Any]]) -> str:
    """Sources nobody has browsed in this run, most productive first."""
    body = [
        "<tr><td><a href=\"%s\">%s</a></td><td class=\"id\">%s</td><td>%s</td><td>%s</td></tr>"
        % (_e(row["home"]), _e(row["name"]), _e(row["id"]), _e(row["kind"]), _e(row["access"]))
        for row in sorted(rows, key=lambda r: (r["rank"], r["kind"], r["id"]))
    ]
    return "<table><thead><tr><th>Source</th><th>Id</th><th>Kind</th><th>Access</th></tr></thead><tbody>%s</tbody></table>" % "".join(body)


def html_report(
    ws: Workspace,
    profile: Profile,
    properties: List[Dict[str, Any]],
    gone: List[Dict[str, Any]],
    dropped: List[Dict[str, Any]],
    coverage: List[Dict[str, Any]],
    rejected_count: int,
    listing_count: int,
) -> str:
    run_year = int(ws.run_date[:4])
    shown = [p for p in properties if p.get("mark") != "dismissed"]
    dismissed = [p for p in properties if p.get("mark") == "dismissed"]
    counts = {status: sum(1 for p in shown if p["status"] == status) for status, _t, _d in SECTIONS}
    new = sum(1 for p in shown if p.get("change") == "new")
    searched = sum(1 for r in coverage if r["outcome"] in ("searched", "partial", "browsed by hand"))
    troubled = sum(1 for r in coverage if r["outcome"] in ("partial", "failed", "incomplete"))
    unsearched = sum(1 for r in coverage if _is_manual(r) and r["covers_profile"])
    out = [
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
        "<title>Japan property search, %s</title><style>%s</style></head><body><main>" % (_e(ws.run), _CSS),
        '<div class="eyebrow">Japan property search · run %s</div>' % _e(ws.run),
        "<h1>%d match%s, %d near, %d unverified</h1>"
        % (counts[criteria.MATCH], "" if counts[criteria.MATCH] == 1 else "es", counts[criteria.NEAR_MISS], counts[criteria.UNVERIFIED]),
        '<p class="lede">%s</p>' % _e(_criteria_summary(profile)),
        '<div class="stats">',
        "<div><b>%d</b><span>New this run</span></div>" % new,
        "<div><b>%d</b><span>Listings read</span></div>" % listing_count,
        "<div><b>%d</b><span>Rejected</span></div>" % rejected_count,
        "<div><b>%d</b><span>Delisted</span></div>" % len(gone),
        "<div><b>%d</b><span>Sources searched</span></div>" % searched,
        "<div><b>%d</b><span>Sources with problems</span></div>" % troubled,
        "<div><b>%d</b><span>Sources not searched</span></div>" % unsearched,
        "</div>",
    ]
    for status, title, blurb in SECTIONS:
        group = sorted((p for p in shown if p["status"] == status), key=_sort_key)
        out.append("<h2>%s (%d)</h2><p class=\"sub\">%s</p>" % (_e(title), len(group), _e(blurb)))
        if not group:
            out.append('<p class="sub">None.</p>')
        out.extend(_card(p, run_year) for p in group)
    if gone:
        out.append("<h2>Delisted since the last run (%d)</h2>" % len(gone))
        out.append("<table><thead><tr><th>Id</th><th>Property</th><th>Last price</th><th>First seen</th></tr></thead><tbody>")
        for row in gone:
            last = row["prices"][-1][1] if row.get("prices") else None
            out.append(
                "<tr><td class=\"id\">%s</td><td>%s<br>%s</td><td>%s</td><td>%s</td></tr>"
                % (_e(row["id"]), _e(row.get("title")), _e(row.get("address")), _e(yen(last)), _e(row.get("first_seen")))
            )
        out.append("</tbody></table>")
    if dropped:
        out.append("<h2>Ruled out since the last run (%d)</h2><p class=\"sub\">Candidates of an earlier run that are still listed "
                   "and that this run's reading rejects.</p>" % len(dropped))
        out.append("<table><thead><tr><th>Id</th><th>Property</th><th>Why</th></tr></thead><tbody>")
        for row in dropped:
            out.append(
                "<tr><td class=\"id\">%s</td><td>%s<br>%s</td><td>%s</td></tr>"
                % (_e(row["id"]), _e(row.get("title")), _e(row.get("address")), _e(row["reason"]))
            )
        out.append("</tbody></table>")
    if dismissed:
        out.append("<h2>Dismissed (%d)</h2><table><tbody>" % len(dismissed))
        for p in sorted(dismissed, key=lambda p: p["id"]):
            out.append(
                "<tr><td class=\"id\">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                % (_e(p["id"]), _e(p.get("title")), _e(yen(p.get("price_jpy"))), _e(p.get("note")))
            )
        out.append("</tbody></table>")
    tried = [r for r in coverage if not _is_manual(r)]
    unbrowsed = [r for r in coverage if _is_manual(r) and r["covers_profile"]]
    out.append("<h2>Coverage</h2><p class=\"sub\">What each source yielded in this run. "
               "Rejected listings and the reason for each are in rejected.csv.</p>")
    out.append(_coverage_table(tried))
    if unbrowsed:
        out.append(
            "<h2>Not searched (%d)</h2><p class=\"sub\">Sources that list property in the profile's areas and were not read in this run: "
            "they have no search this tool can run, or they keep automated browsers out. Most productive first. "
            "<code>jpsearch sources --id ID</code> prints how to search one by hand.</p>" % len(unbrowsed)
        )
        out.append(_manual_table(unbrowsed))
    out.append("</main></body></html>")
    return "\n".join(out)


# ---------------------------------------------------------------- Markdown, CSV, JSON


def markdown_report(
    ws: Workspace,
    profile: Profile,
    properties: List[Dict[str, Any]],
    gone: List[Dict[str, Any]],
    dropped: List[Dict[str, Any]],
    coverage: List[Dict[str, Any]],
) -> str:
    shown = [p for p in properties if p.get("mark") != "dismissed"]
    lines = ["# Japan property search, run %s" % ws.run, "", _criteria_summary(profile), ""]
    for status, title, _blurb in SECTIONS:
        group = sorted((p for p in shown if p["status"] == status), key=_sort_key)
        lines += ["## %s (%d)" % (title, len(group)), ""]
        if not group:
            lines += ["None.", ""]
            continue
        lines += ["| Id | Price | Land m² | Building m² | Built | Structure | Location | Change | Open point | Link |", "|---|---|---|---|---|---|---|---|---|---|"]
        for p in group:
            lines.append(
                "| %s | %s | %s | %s | %s | %s | %s | %s | %s | [%s](%s) |"
                % (
                    p["id"],
                    oku_man(p.get("price_jpy")) or "on request",
                    "%.0f" % p["land_m2"] if p.get("land_m2") else "?",
                    "%.0f" % p["building_m2"] if p.get("building_m2") else "?",
                    p.get("built_year") or "?",
                    structure_label(p).replace("|", "/"),
                    (p.get("address") or "?").replace("|", "/"),
                    CHANGE_LABELS.get(p.get("change") or "", ""),
                    "; ".join(p.get("open_points") or []).replace("|", "/"),
                    (p.get("sources") or ["source"])[0] + (" +%d" % (len(p["listings"]) - 1) if len(p.get("listings") or []) > 1 else ""),
                    (p.get("urls") or [""])[0],
                )
            )
        lines.append("")
    if gone:
        lines += ["## Delisted since the last run (%d)" % len(gone), ""]
        lines += ["- %s: %s, %s" % (g["id"], g.get("title") or "", g.get("address") or "") for g in gone]
        lines.append("")
    if dropped:
        lines += ["## Ruled out since the last run (%d)" % len(dropped), ""]
        lines += ["- %s: %s, %s: %s" % (d["id"], d.get("title") or "", d.get("address") or "", d["reason"]) for d in dropped]
        lines.append("")
    lines += ["## Coverage", "", "| Source | Outcome | Pages | Cards | Detail pages | Notes |", "|---|---|---|---|---|---|"]
    for row in coverage:
        if not _is_manual(row):
            lines.append(
                "| %s | %s | %d | %d | %d | %s |"
                % (row["name"], row["outcome"], row["pages"], row["cards"], row["details"], coverage_note(row).replace("|", "/"))
            )
    unbrowsed = sorted((r for r in coverage if _is_manual(r) and r["covers_profile"]), key=lambda r: (r["rank"], r["kind"], r["id"]))
    if unbrowsed:
        lines += ["", "Not searched, to browse by hand (%d, most productive first): %s." % (len(unbrowsed), ", ".join(r["id"] for r in unbrowsed))]
    lines.append("")
    return "\n".join(lines)


_CSV_FIELDS = (
    "id", "status", "change", "mark", "zone", "price_jpy", "price_max_jpy", "land_m2", "building_m2", "built_year",
    "built_month", "structure", "structure_text", "floors", "basement", "layout", "prefecture", "municipality", "address",
    "access", "land_right", "zoning", "coverage_far", "road", "water", "sewer", "gas", "hot_spring", "management_fee",
    "flags", "open_points", "first_seen", "sources", "listing_count", "url", "all_urls", "title", "note",
)


def _csv_row(prop: Dict[str, Any]) -> Dict[str, Any]:
    row = {f: prop.get(f) for f in _CSV_FIELDS}
    row["flags"] = "; ".join(prop.get("flags") or [])
    row["open_points"] = "; ".join(prop.get("open_points") or [])
    row["sources"] = "; ".join(prop.get("sources") or [])
    row["listing_count"] = len(prop.get("listings") or [])
    row["url"] = (prop.get("urls") or [""])[0]
    row["all_urls"] = " ".join(prop.get("urls") or [])
    return row


def write_all(
    ws: Workspace,
    profile: Profile,
    properties: List[Dict[str, Any]],
    rejected: List[Dict[str, Any]],
    gone: List[Dict[str, Any]],
    dropped: List[Dict[str, Any]],
    coverage: List[Dict[str, Any]],
    listing_count: int,
) -> Dict[str, str]:
    """Write every output file for the run and return their paths by name."""
    run = ws.run_dir
    run.mkdir(parents=True, exist_ok=True)
    paths = {
        "html": run / "report.html",
        "markdown": run / "report.md",
        "json": run / "candidates.json",
        "csv": run / "candidates.csv",
        "rejected": run / "rejected.csv",
        "coverage": run / "coverage.json",
    }
    paths["html"].write_text(html_report(ws, profile, properties, gone, dropped, coverage, len(rejected), listing_count), encoding="utf-8")
    paths["markdown"].write_text(markdown_report(ws, profile, properties, gone, dropped, coverage), encoding="utf-8")
    write_json(paths["json"], {"run": ws.run, "profile": profile.name, "properties": properties, "delisted": gone, "ruled_out": dropped})
    write_json(paths["coverage"], coverage)
    with paths["csv"].open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=_CSV_FIELDS)
        writer.writeheader()
        for prop in sorted(properties, key=lambda p: (p["status"], _sort_key(p))):
            writer.writerow(_csv_row(prop))
    with paths["rejected"].open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["source", "url", "reason", "price_jpy", "land_m2", "building_m2", "structure", "built_year", "address", "title"])
        for item in rejected:
            writer.writerow([item.get(k) for k in ("source", "url", "reason", "price_jpy", "land_m2", "building_m2", "structure", "built_year", "address", "title")])
    return {name: str(path) for name, path in paths.items()}
