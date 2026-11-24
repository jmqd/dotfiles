"""Merge the captured pages of one listing into listing.json.

A listing is usually spread over a main page and sub-pages (overview,
surroundings, equipment). Each is captured with JPX.detail(); this joins them
into one ordered record of everything the listing says and shows, which is
what gets translated.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qsl, urlsplit

from store import BrochureError, Folder, read_json, write_json

_IMAGE_FILE = re.compile(r"\.(?:jpe?g|png|webp|gif|avif)$", re.I)
# Below this many pixels a side, an <img> shows nothing a buyer would look at.
_SPECK = 50


def _photo_key(image: Dict[str, Any]) -> str:
    return (image.get("candidates") or [image["url"]])[0]


def _file_names(url: str) -> List[str]:
    """The parts of an image URL that can name its file: the path, and query values that are image files.

    The rest of a query string says nothing about the picture. A tracking
    pixel echoes the address of the page it sits on there, listing number
    included.
    """
    parts = urlsplit(url)
    return [parts.path] + [value for _key, value in parse_qsl(parts.query) if _IMAGE_FILE.search(value)]


def _is_beacon(image: Dict[str, Any]) -> bool:
    """A tracking pixel: an <img> that names no image file, loaded no picture and takes no room on the page."""
    if image.get("how") != "img" or any(_IMAGE_FILE.search(name) for name in _file_names(image["url"])):
        return False
    loaded = min(int(image.get("w") or 0), int(image.get("h") or 0))
    box = [int(side) for side in re.findall(r"\d+", image.get("shown") or "")] or [0]
    return loaded < _SPECK and min(box) < _SPECK


def _names_listing(number: str, photo: Dict[str, Any]) -> bool:
    return any(number in name for name in _file_names(_photo_key(photo)))


def _listing_number(page_url: str, on_page: List[Dict[str, Any]]) -> Optional[str]:
    """The listing's id, when the site also puts it in the URLs of this listing's photos.

    A listing page shows other properties too (the agent's other stock,
    recommendations). Where photo URLs carry the listing id, that id tells
    this property's photos from theirs; where they do not, None is returned
    and nothing is filtered. `on_page` are the photos found on that page.
    """
    for number in reversed(re.findall(r"\d{6,}", urlsplit(page_url).path)):
        carrying = [p for p in on_page if _names_listing(number, p)]
        if on_page and len(carrying) >= 3 and len(carrying) * 3 >= len(on_page):
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
            if image.get("chrome") or image.get("tiny") or _is_beacon(image):
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
                    # Pixels of the image as the page loaded it; 0 when it was only referenced.
                    "page_pixels": int(image.get("w") or 0) * int(image.get("h") or 0),
                }
            else:
                for field in ("category", "caption", "section"):
                    known[field] = known[field] or image.get(field) or (image.get("alt") if field == "category" else "") or ""
                known["page_pixels"] = max(known["page_pixels"], int(image.get("w") or 0) * int(image.get("h") or 0))
        for pdf in capture.get("pdfs") or []:
            pdfs.setdefault(pdf["url"], pdf)
        for sub in capture.get("subpages") or []:
            subpages.setdefault(sub["url"].split("?")[0], sub.get("text") or "")

    captured_urls = {p["url"].split("?")[0] for p in pages}
    found = list(photos.values())
    # Each site numbers the listing its own way, so the id is worked out once per
    # site, from its first captured page, and applied to that site's pages only.
    host_of_page = {page["page"]: urlsplit(page["url"]).netloc for page in pages}
    number_for_host: Dict[str, Optional[str]] = {}
    for page in pages:
        host = host_of_page[page["page"]]
        if host not in number_for_host:
            number_for_host[host] = _listing_number(page["url"], [p for p in found if p["page"] == page["page"]])
    # brochure.json and photos.json name photos by id, so a photo keeps the id an earlier ingest gave
    # it and an id once issued is never given to another photo. Capturing one more page then adds
    # photos without making the names already in use point at different pictures.
    earlier = read_json(folder.listing) or {}
    issued_to = {_photo_key(photo): photo["id"] for photo in earlier.get("photos") or []}
    issued = int(earlier.get("photo_ids_issued") or len(issued_to))
    ordered = []
    others = []
    for photo in found:
        number = number_for_host[host_of_page[photo["page"]]]
        if number is not None and not _names_listing(number, photo):
            others.append({"url": _photo_key(photo), "category": photo["category"], "page": photo["page"]})
            continue
        photo_id = issued_to.get(_photo_key(photo))
        if photo_id is None:
            issued += 1
            photo_id = "p%03d" % issued
        ordered.append(dict(photo, id=photo_id))
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
        "photo_ids_issued": issued,
        # Images on the pages whose URLs do not carry this listing's id: staff, the shop, other properties.
        "other_images": others,
        "pdfs": list(pdfs.values()),
        "uncaptured_subpages": [{"url": url, "text": text} for url, text in subpages.items() if url not in captured_urls],
        "furniture_images_skipped": furniture,
    }
    write_json(folder.listing, listing)
    return listing
