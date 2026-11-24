"""Merge the captured pages of one listing into listing.json.

A listing is usually spread over a main page and sub-pages (overview,
surroundings, equipment). Each is captured with JPX.detail(); this joins them
into one ordered record of everything the listing says and shows, which is
what gets translated.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit

from store import BrochureError, Folder, read_json, write_json


def _photo_key(image: Dict[str, Any]) -> str:
    return (image.get("candidates") or [image["url"]])[0]


def _listing_number(listing_url: str, photos: List[Dict[str, Any]]) -> Optional[str]:
    """The listing's id, when the site also puts it in the URLs of this listing's photos.

    A listing page shows other properties too (the agent's other stock,
    recommendations). Where photo URLs carry the listing id, that id tells
    this property's photos from theirs; where they do not, None is returned
    and nothing is filtered.
    """
    for number in reversed(re.findall(r"\d{6,}", urlsplit(listing_url).path)):
        on_main = [p for p in photos if p["page"] == 1]
        carrying = [p for p in on_main if number in _photo_key(p)]
        if on_main and len(carrying) >= 3 and len(carrying) * 3 >= len(on_main):
            return number
    return None


def merge(folder: Folder) -> Dict[str, Any]:
    files = sorted(folder.capture_dir.glob("*.json")) if folder.capture_dir.exists() else []
    if not files:
        raise BrochureError(
            "no captures in %s; capture the listing page with JPX.detail() first (see SKILL.md, step 1)" % folder.capture_dir
        )
    pages: List[Dict[str, Any]] = []
    pairs: List[Dict[str, Any]] = []
    blocks: List[Dict[str, Any]] = []
    photos: Dict[str, Dict[str, Any]] = {}
    furniture = 0
    seen_pairs = set()
    seen_blocks = set()
    pdfs: Dict[str, Dict[str, Any]] = {}
    subpages: Dict[str, str] = {}
    for number, path in enumerate(files, start=1):
        capture = read_json(path) or {}
        if not isinstance(capture.get("pairs"), list) or not capture.get("url"):
            raise BrochureError("%s is not JPX.detail() output (it needs 'url' and 'pairs')" % path)
        if capture.get("blocked") and not capture["pairs"]:
            raise BrochureError("%s captured a block page (%s), not the listing" % (path, ", ".join(capture["blocked"])))
        pages.append({"page": number, "file": path.name, "url": capture["url"], "title": capture.get("title"), "h1": capture.get("h1"),
                      "captured_at": capture.get("captured_at"), "coords": capture.get("coords") or []})
        for pair in capture["pairs"]:
            key = (pair.get("label"), pair.get("value"))
            if key not in seen_pairs:
                seen_pairs.add(key)
                pairs.append({"label": pair.get("label"), "value": pair.get("value"), "section": pair.get("section") or "", "page": number})
        for block in capture.get("blocks") or []:
            if block.get("text") not in seen_blocks:
                seen_blocks.add(block.get("text"))
                blocks.append({"text": block.get("text"), "section": block.get("section") or "", "page": number})
        for image in capture.get("images") or []:
            if image.get("chrome") or image.get("tiny"):
                furniture += 1
                continue
            key = _photo_key(image)
            known = photos.get(key)
            if known is None:
                photos[key] = {
                    "url": image["url"],
                    "candidates": image.get("candidates") or [image["url"]],
                    "category": image.get("category") or image.get("alt") or "",
                    "caption": image.get("caption") or "",
                    "section": image.get("section") or "",
                    "page": number,
                }
            else:
                for field in ("category", "caption", "section"):
                    known[field] = known[field] or image.get(field) or (image.get("alt") if field == "category" else "") or ""
        for pdf in capture.get("pdfs") or []:
            pdfs.setdefault(pdf["url"], pdf)
        for sub in capture.get("subpages") or []:
            subpages.setdefault(sub["url"].split("?")[0], sub.get("text") or "")

    captured_urls = {p["url"].split("?")[0] for p in pages}
    found = list(photos.values())
    number = _listing_number(pages[0]["url"], found)
    ordered = []
    others = []
    for photo in found:
        if number is None or number in _photo_key(photo):
            ordered.append(dict(photo, id="p%03d" % (len(ordered) + 1)))
        else:
            others.append({"url": _photo_key(photo), "category": photo["category"], "page": photo["page"]})
    listing = {
        "url": pages[0]["url"],
        "title": pages[0]["title"],
        "h1": pages[0]["h1"],
        "captured_at": pages[0]["captured_at"],
        "pages": pages,
        # Only the first page's map is the property's; a shop page carries the agent's own.
        "coords": pages[0]["coords"],
        "pairs": pairs,
        "blocks": blocks,
        "photos": ordered,
        # Images on the pages whose URLs do not carry this listing's id: staff, the shop, other properties.
        "other_images": others,
        "pdfs": list(pdfs.values()),
        "uncaptured_subpages": [{"url": url, "text": text} for url, text in subpages.items() if url not in captured_urls],
        "furniture_images_skipped": furniture,
    }
    write_json(folder.listing, listing)
    return listing
