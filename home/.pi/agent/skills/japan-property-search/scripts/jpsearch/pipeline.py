"""Read a run's raw captures and turn them into listings.

Every capture file is an envelope the collector wrote:

    {"task": {...}, "fetched_at": "...", "error": null, "result": {...}}

Captures are never modified, so a parsing fix can be re-run over old data.
"""

from __future__ import annotations

import datetime
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

import criteria
import dedupe
import listings
import text
from workspace import Workspace, read_json

OK, BLOCKED, ERROR, DRIFT, EMPTY, GONE = "ok", "blocked", "error", "drift", "empty", "gone"

# What a portal's page says once a listing has been taken down.
_WITHDRAWN = re.compile(r"エラー|見つかりません|掲載(?:が|は)?終了|公開(?:が|は)?終了|存在しません|削除され|not found|no longer available|\b404\b", re.I)
# The title of an error page that a server or its CDN sent in place of the page asked for.
_ERROR_PAGE = re.compile(
    r"^\s*[45]\d\d\b|bad gateway|gateway time-?out|service unavailable|internal server error|could not be satisfied|システムエラー", re.I
)
_NOT_THERE = (404, 410)


@dataclass
class Page:
    """One captured results page and what it yielded."""

    path: Path
    task: Dict[str, Any]
    status: str
    note: str
    cards: List[Dict[str, Any]]
    hits: Optional[int]
    next_url: Optional[str]


def _hits(value: object) -> Optional[int]:
    digits = "".join(c for c in text.nfkc(value) if c.isdigit())
    return int(digits) if digits else None


def read_page(path: Path) -> Page:
    envelope = read_json(path) or {}
    task = envelope.get("task") or {}
    result = envelope.get("result") or {}
    found = result.get("cards") or []
    cards = [c for c in found if c.get("url")]
    info = result.get("info") or {}
    hits = _hits(info.get("hits"))
    if envelope.get("error"):
        return Page(path, task, ERROR, str(envelope["error"])[:200], [], hits, None)
    if envelope.get("http_status") in _NOT_THERE:
        return Page(path, task, DRIFT, "the search URL returned HTTP %d: the site's URL form has changed" % envelope["http_status"], [], hits, None)
    if result.get("blocked") and not cards:
        return Page(path, task, BLOCKED, "block page: " + ", ".join(result["blocked"])[:160], [], hits, None)
    unlinked = len(found) - len(cards)
    if unlinked > len(cards):
        # Cards were recognised but most carry no link to their listing. Read on, the page would pass
        # for a short one, or for "no listings" where the site states no hit count.
        note = "%d of %d cards have no link to a listing: the site's markup has changed" % (unlinked, len(found))
        return Page(path, task, DRIFT, note, [], hits, None)
    if not cards:
        title = text.squash(info.get("title"))
        if _ERROR_PAGE.search(title):
            # An error page holds no cards either; reading it as "no listings" would hide a failed search.
            return Page(path, task, ERROR, "the site answered with an error page: %s" % title[:80], [], hits, None)
        if hits:
            return Page(path, task, DRIFT, "page reports %d hits but no cards were recognised" % hits, [], hits, None)
        return Page(path, task, EMPTY, "no listings", [], hits, info.get("next"))
    return Page(path, task, OK, "", cards, hits, info.get("next"))


def list_pages(ws: Workspace) -> Iterator[Page]:
    root = ws.raw_dir / "list"
    if not root.exists():
        return
    for path in sorted(root.glob("*/*.json")):
        yield read_page(path)


def card_listings(ws: Workspace, pages: Optional[List[Page]] = None) -> Dict[str, Dict[str, Any]]:
    """Listings from result cards, keyed by URL. A URL seen on several pages keeps its first record."""
    out: Dict[str, Dict[str, Any]] = {}
    for page in pages if pages is not None else list_pages(ws):
        if page.status != OK:
            continue
        for card in page.cards:
            url = card["url"]
            if url in out:
                continue
            out[url] = listings.normalise(
                page.task.get("source") or "unknown",
                page.task.get("listing_type") or "used_house",
                url,
                card.get("title"),
                card.get("pairs") or [],
                card.get("text"),
                card.get("image"),
                ws.run_date,
                prefecture_hint=page.task.get("prefecture"),
            )
    return out


def page_is_parsed_well(page: Page, records: List[Dict[str, Any]]) -> bool:
    """False when most cards yielded neither a price nor an area: the site's markup has drifted."""
    if not records:
        return False
    useful = sum(1 for r in records if r.get("price_jpy") or r.get("land_m2") or r.get("building_m2"))
    return useful * 2 >= len(records)


@dataclass
class DetailCapture:
    url: str
    status: str
    note: str
    record: Optional[Dict[str, Any]]


def read_detail(path: Path, run_date: str) -> DetailCapture:
    envelope = read_json(path) or {}
    task = envelope.get("task") or {}
    url = task.get("url") or ""
    result = envelope.get("result") or {}
    if envelope.get("error"):
        return DetailCapture(url, ERROR, str(envelope["error"])[:200], None)
    if envelope.get("http_status") in _NOT_THERE:
        return DetailCapture(url, GONE, "the listing page is no longer available (HTTP %d): it may have been withdrawn" % envelope["http_status"], None)
    record = listings.from_detail_capture(
        task.get("source") or "unknown", task.get("listing_type") or "used_house", result, run_date
    )
    record["url"] = url
    stated = [f for f in ("price_jpy", "land_m2", "building_m2", "structure", "address") if record.get(f)]
    if result.get("blocked") and not stated:
        return DetailCapture(url, BLOCKED, "block page: " + ", ".join(result["blocked"])[:160], None)
    if not stated:
        if _WITHDRAWN.search("%s\n%s" % (result.get("title") or "", result.get("h1") or "")):
            return DetailCapture(url, GONE, "the listing page is no longer available: it may have been withdrawn", None)
        return DetailCapture(url, DRIFT, "no property fields recognised on the page", None)
    return DetailCapture(url, OK, "", record)


def detail_captures(ws: Workspace) -> Dict[str, DetailCapture]:
    root = ws.raw_dir / "detail"
    out: Dict[str, DetailCapture] = {}
    if root.exists():
        for path in sorted(root.glob("*.json")):
            capture = read_detail(path, ws.run_date)
            if capture.url:
                out[capture.url] = capture
    return out


def cached_details(state: Dict[str, Any], run_date: str, max_age_days: int) -> Dict[str, Dict[str, Any]]:
    """Detail records from earlier runs that are still fresh enough to trust."""
    today = datetime.date.fromisoformat(run_date)
    out = {}
    for url, entry in (state.get("details") or {}).items():
        captured = datetime.date.fromisoformat(entry["captured"])
        if (today - captured).days <= max_age_days:
            out[url] = entry["record"]
    return out


def merged_listings(
    cards: Dict[str, Dict[str, Any]], details: Dict[str, Dict[str, Any]], captures: Dict[str, DetailCapture]
) -> List[Dict[str, Any]]:
    """Card listings completed with their detail records, plus listings captured only as a detail page.

    The second kind comes from browsing by hand: someone opened a property
    page directly and saved it, so no result card exists for it.
    """
    out = []
    for url, card in cards.items():
        detail = details.get(url)
        # A cached detail describes the listing as it was; a changed price means the page changed.
        if detail and detail.get("price_jpy") and card.get("price_jpy") and detail["price_jpy"] != card["price_jpy"]:
            detail = dict(detail, price_jpy=None, price_max_jpy=None, price_text=None)
        out.append(listings.merge_detail(card, detail) if detail else card)
    for url, capture in sorted(captures.items()):
        if capture.record and url not in cards:
            out.append(capture.record)
    return out


def usable_details(ws: Workspace, state: Dict[str, Any], max_age_days: int) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, DetailCapture]]:
    """(detail records by URL from this run and the cache, this run's captures by URL)."""
    captures = detail_captures(ws)
    records = cached_details(state, ws.run_date, max_age_days)
    for url, capture in captures.items():
        if capture.record:
            records[url] = capture.record
    return records, captures


@dataclass
class Judged:
    """One property, the verdict on it, and the listings that advertise it."""

    prop: Dict[str, Any]
    verdict: criteria.Verdict
    listings: List[Dict[str, Any]]


def judged_properties(profile: criteria.Profile, merged: List[Dict[str, Any]]) -> List[Judged]:
    """Group every listing into properties and judge each property once.

    Listings are grouped before judging, not after, so that a fact only one
    agent states (the structure, a tenant) counts for the whole property.
    """
    out = []
    for group in dedupe.cluster(merged):
        prop = dedupe.merge(group)
        out.append(Judged(prop, criteria.judge(profile, prop), group))
    return out
