"""Write a first brochure.json from the listing, with every Japanese string marked for translation.

The draft places every field and every photo, so the translator's job is to
translate, regroup and prune, and nothing is left out by forgetting it. Each
string that still needs work starts with "JA: "; the build refuses to run
while any remains.
"""

from __future__ import annotations

import datetime
import re
from typing import Any, Dict, List
from urllib.parse import urlsplit

from render import DRAFT_PREFIX
from store import BrochureError, Folder, read_json, write_json

_SITES = {
    "suumo.jp": "SUUMO",
    "athome.co.jp": "at home",
    "homes.co.jp": "LIFULL HOME'S",
    "realestate.yahoo.co.jp": "Yahoo! Real Estate",
    "rehouse.co.jp": "Mitsui Rehouse",
    "livable.co.jp": "Tokyu Livable",
    "nomu.com": "Nomura no Chukai+",
    "stepon.co.jp": "Sumitomo Real Estate Step",
}

# Cover facts: English label -> Japanese labels that carry it, first match wins.
_FACTS = (
    ("Price", ("価格", "販売価格", "物件価格")),
    ("Layout", ("間取り", "間取")),
    ("Building", ("建物面積", "延床面積", "延べ床面積")),
    ("Land", ("土地面積", "敷地面積")),
    ("Built", ("完成時期", "築年月", "築年数", "建築年月")),
    ("Access", ("交通", "沿線・駅", "最寄駅", "最寄り駅")),
)

_FLOOR_PLAN = re.compile(r"間取")
_LOT_PLAN = re.compile(r"区画図|敷地図|配置図|地形図|測量図|公図|地積|土地図")
_MAP = re.compile(r"地図|案内図|アクセス図|路線図|マップ")
_NEIGHBOURHOOD = re.compile(
    r"周辺|スーパー|コンビニ|ショッピング|学校|小学校|中学校|高校|幼稚園|保育園|公園|病院|クリニック|郵便局|銀行|役所|駅|図書館|ドラッグ|ホームセンター"
)


def _ja(value: object) -> str:
    return DRAFT_PREFIX + str(value or "").strip()


def site_name(url: str) -> str:
    host = (urlsplit(url).hostname or "").replace("www.", "")
    for domain, name in _SITES.items():
        if host == domain or host.endswith("." + domain):
            return name
    return host


def _listing_id(url: str) -> str:
    numbers = re.findall(r"\d{5,}", urlsplit(url).path)
    return numbers[-1] if numbers else ""


def build(folder: Folder, overwrite: bool = False) -> Dict[str, Any]:
    if folder.content.exists() and not overwrite:
        raise BrochureError("%s already exists; pass --overwrite to replace it with a fresh draft" % folder.content)
    listing = folder.require(folder.listing, "run `brochure ingest` first")
    photos = (read_json(folder.photos) or {"photos": []})["photos"]
    maps = (read_json(folder.maps) or {"maps": []})["maps"]
    site = site_name(listing["url"])
    first = {}
    for pair in listing["pairs"]:
        first.setdefault(pair["label"], pair["value"])
        # 完成時期（築年月） and 完成時期 are the same field.
        first.setdefault(re.sub(r"[（(].*?[）)]", "", pair["label"]), pair["value"])

    facts = []
    for english, labels in _FACTS:
        label = next((l for l in labels if l in first), None)
        if label:
            facts.append({"label": english, "value": _ja(first[label]), "note": ""})

    groups: Dict[str, List[Dict[str, Any]]] = {"floor": [], "lot": [], "map": [], "near": [], "main": []}
    omitted = []
    for photo in photos:
        if photo.get("status") == "duplicate":
            continue
        if photo.get("status") != "ok":
            omitted.append({"photo": photo["id"], "reason": _ja("download failed: " + "; ".join(photo.get("errors") or [])[:160])})
            continue
        category = photo.get("category") or ""
        if _FLOOR_PLAN.search(category):
            groups["floor"].append(photo)
        elif _LOT_PLAN.search(category):
            groups["lot"].append(photo)
        elif _MAP.search(category):
            groups["map"].append(photo)
        elif _NEIGHBOURHOOD.search(category):
            groups["near"].append(photo)
        else:
            groups["main"].append(photo)

    def item(photo: Dict[str, Any]) -> Dict[str, Any]:
        return {"photo": photo["id"], "label": _ja(photo.get("category")), "caption": _ja(photo.get("caption"))}

    sections: List[Dict[str, Any]] = [
        {
            "type": "table",
            "title": "Property details",
            "rows": [
                {"label": _ja(pair["label"]), "value": _ja(pair["value"]), "ja_label": pair["label"], "ja": ""}
                for pair in listing["pairs"]
            ],
        }
    ]
    if listing.get("blocks"):
        sections.append({"type": "text", "title": "From the listing", "paragraphs": [_ja(b["text"]) for b in listing["blocks"]]})
    if groups["main"]:
        sections.append({"type": "photos", "title": "Photos", "columns": 2, "items": [item(p) for p in groups["main"]]})
    for key, title in (("floor", "Floor plan"), ("lot", "Lot plan")):
        for photo in groups[key]:
            sections.append({
                "type": "plan", "title": title, "photo": photo["id"], "caption": _ja(photo.get("caption")),
                "labels": [{"label": _ja("label printed on the plan"), "text": _ja("its meaning")}],
            })
    if groups["map"]:
        sections.append({"type": "photos", "title": "Maps and access", "columns": 2, "items": [dict(item(p), fit="contain") for p in groups["map"]]})
    if maps:
        sections.append({
            "type": "maps", "title": "Location",
            "items": [{"map": m["id"], "caption": _ja("say what the map shows and how exact the marker is")} for m in maps],
        })
    if groups["near"]:
        sections.append({
            "type": "cards", "title": "Neighbourhood",
            "items": [{"photo": p["id"], "title": _ja(p.get("category")), "text": _ja(p.get("caption"))} for p in groups["near"]],
        })
    sections.append({
        "type": "notes", "title": "Translator's notes",
        "glossary": [{"term": _ja("term used above"), "meaning": _ja("plain explanation")}],
        "groups": [
            {"title": "Left as written in the source", "items": [_ja("inconsistencies in the listing, reported, not resolved")]},
            {"title": "Not stated on the listing", "items": [_ja("fields the listing leaves blank")]},
        ],
    })

    listing_id = _listing_id(listing["url"])
    content = {
        "eyebrow": "%s listing%s · English translation" % (site, " no. " + listing_id if listing_id else ""),
        "title": _ja(listing.get("h1") or listing.get("title")),
        "subtitle": _ja("one sentence from the listing's own headline or lead"),
        "tagline": "",
        "short_name": _ja("short English name for the page footer, e.g. Minami-Ogikubo 1-chōme RC house"),
        "source": {
            "site": site,
            "url": listing["url"].split("?")[0],
            "listing_id": listing_id,
            "information_date": _ja(first.get("情報提供日") or first.get("情報更新日") or first.get("情報公開日") or ""),
            "next_update": _ja(first.get("次回更新予定日") or ""),
            "translated_on": "%d %s" % (datetime.date.today().day, datetime.date.today().strftime("%B %Y")),
        },
        "hero_photo": (groups["main"] or photos or [{"id": ""}])[0]["id"],
        "key_facts": facts,
        "summary": _ja("type of property · address · handover · listing agent"),
        "sections": sections,
        "omitted_photos": omitted,
        "ignored_labels": [],
    }
    write_json(folder.content, content)
    return content
