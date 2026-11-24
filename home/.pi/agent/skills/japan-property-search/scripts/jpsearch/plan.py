"""Work out what a run still has to fetch.

The plan is a pure function of the profile, the registry and the captures
already on disk. Collecting is therefore a loop: build the plan, fetch every
task marked `todo`, build the plan again. Each capture can add tasks (the next
results page, the detail page of a promising card), and a task whose output
file exists is never `todo` again, so the loop ends and can be resumed after
any interruption.

robots.txt is the authority on what may be fetched. A host's tasks stay
`waiting` until its robots.txt has been captured, and become `disallowed` when
robots.txt forbids the URL or could not be read.
"""

from __future__ import annotations

import datetime
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit

import criteria
import dedupe
import pipeline
import robots
from criteria import Profile
from registry import Search, Source
from workspace import Workspace, read_json, write_json

TODO, DONE, FAILED, DISALLOWED, WAITING, DEFERRED = "todo", "done", "failed", "disallowed", "waiting", "deferred"

DISCOVER_CACHE_DAYS = 30
MAX_DETAIL_TRIES_PER_PROPERTY = 3


@dataclass(frozen=True)
class RobotsVerdict:
    """What a host's robots.txt capture means: rules to apply, no rules, or keep out."""

    state: str  # pending | rules | open | closed
    rules: Optional[str]
    note: str


def robots_verdict(envelope: Optional[Dict[str, Any]]) -> RobotsVerdict:
    if envelope is None:
        return RobotsVerdict("pending", None, "robots.txt not fetched yet")
    if envelope.get("error"):
        return RobotsVerdict("closed", None, "robots.txt could not be loaded: %s" % str(envelope["error"])[:120])
    result = envelope.get("result") or {}
    status = result.get("status")
    body = result.get("text") or ""
    if status in (404, 410):
        return RobotsVerdict("open", None, "site has no robots.txt (HTTP %s)" % status)
    if status != 200:
        # A 403 or 5xx on robots.txt is the site declining automated visitors.
        return RobotsVerdict("closed", None, "robots.txt returned HTTP %s" % status)
    if not re.search(r"(?im)^\s*(user-agent|disallow|allow|sitemap)\s*:", body):
        if re.search(r"<html|<!doctype", body, re.I):
            return RobotsVerdict("open", None, "robots.txt URL serves a web page, not rules")
        return RobotsVerdict("open", None, "robots.txt is empty")
    return RobotsVerdict("rules", body, "robots.txt read")


def _host(url: str) -> str:
    return urlsplit(url).hostname or ""


def _fresh(date_text: str, today: str, max_days: int) -> bool:
    age = datetime.date.fromisoformat(today) - datetime.date.fromisoformat(date_text)
    return age.days <= max_days


def parse_cities(envelope: Dict[str, Any], link: "re.Pattern[str]") -> List[Dict[str, Any]]:
    """Cities from a captured index page: [{slug, name, count}], count None when not shown."""
    cities: Dict[str, Dict[str, Any]] = {}
    for item in (envelope.get("result") or {}).get("links") or []:
        m = link.search(item.get("href") or "")
        if not m:
            continue
        label = re.sub(r"\s+", " ", item.get("text") or "").strip()
        count_match = re.search(r"[((]\s*([\d,]+)\s*[))]|([\d,]+)\s*件", label)
        count = int((count_match.group(1) or count_match.group(2)).replace(",", "")) if count_match else None
        name = re.sub(r"[((].*$|[\d,]+\s*件.*$", "", label).strip()
        slug = m.group(1)
        if slug not in cities or (not cities[slug]["name"] and name):
            cities[slug] = {"slug": slug, "name": name, "count": count}
    return [c for c in cities.values() if c["count"] != 0]


class Planner:
    def __init__(self, ws: Workspace, profile: Profile, sources: List[Source], state: Dict[str, Any]) -> None:
        self.ws = ws
        self.profile = profile
        self.sources = sources
        self.state = state
        self.tasks: List[Dict[str, Any]] = []
        self.cards: Dict[str, Dict[str, Any]] = {}
        self._robots: Dict[str, RobotsVerdict] = {}

    # ------------------------------------------------------------ robots

    def _verdict(self, url: str) -> RobotsVerdict:
        parts = urlsplit(url)
        host = parts.hostname or ""
        if host not in self._robots:
            path = self.ws.robots_path(host)
            envelope = read_json(path)
            verdict = robots_verdict(envelope)
            self._robots[host] = verdict
            self.tasks.append(
                {
                    "id": "robots:" + host,
                    "kind": "robots",
                    "source": None,
                    "host": host,
                    "url": "%s://%s/robots.txt" % (parts.scheme or "https", parts.netloc),
                    "out": self.ws.relative(path),
                    "status": TODO if envelope is None else DONE,
                    "why": verdict.note,
                    "extract": {"fn": "robots"},
                }
            )
        return self._robots[host]

    def _status(self, url: str, out: Path) -> Tuple[str, str]:
        verdict = self._verdict(url)
        if out.exists():
            return DONE, ""
        if verdict.state == "pending":
            return WAITING, "waiting for robots.txt"
        if verdict.state == "closed":
            return DISALLOWED, verdict.note
        if verdict.state == "rules" and not robots.allowed(verdict.rules, url):
            return DISALLOWED, "robots.txt disallows this URL"
        return TODO, ""

    def _delay(self, host: str) -> float:
        verdict = self._robots.get(host)
        stated = robots.crawl_delay(verdict.rules) if verdict and verdict.rules else None
        return max(self.profile.request_delay_seconds, stated or 0.0)

    # ------------------------------------------------------------ searches

    def _selected(self, source: Source) -> bool:
        if self.profile.sources and source.id not in self.profile.sources:
            return False
        return source.id not in self.profile.exclude_sources

    def _cities(self, source: Source, search: Search, prefecture: str) -> Optional[List[Dict[str, Any]]]:
        assert search.discover is not None, "registry guarantees discover for city scope"
        pref_slug = search.pref_slug(prefecture)
        cache_path = self.ws.discover_cache_path(source.id, search.listing_type, pref_slug)
        cached = read_json(cache_path)
        if cached and _fresh(cached["fetched"], self.ws.run_date, DISCOVER_CACHE_DAYS):
            return cached["cities"]
        url = search.discover.url.format(pref=pref_slug)
        out = self.ws.discover_run_path(source.id, "%s-%s" % (search.listing_type, pref_slug))
        status, why = self._status(url, out)
        cities = None
        if status == DONE:
            envelope = read_json(out) or {}
            if envelope.get("error"):
                status, why = FAILED, str(envelope["error"])[:200]
            else:
                cities = parse_cities(envelope, search.discover.link)
                if cities:
                    write_json(cache_path, {"fetched": self.ws.run_date, "url": url, "cities": cities})
                else:
                    status, why, cities = FAILED, "no city links matched %s" % search.discover.link.pattern, None
        self.tasks.append(
            {
                "id": "discover:%s:%s:%s" % (source.id, search.listing_type, pref_slug),
                "kind": "discover",
                "source": source.id,
                "host": _host(url),
                "url": url,
                "out": self.ws.relative(out),
                "status": status,
                "why": why,
                "extract": {"fn": "links", "pattern": search.discover.link.pattern},
            }
        )
        return cities

    def _next_url(
        self,
        search: Search,
        page: pipeline.Page,
        records: List[Dict[str, Any]],
        prefecture: Optional[str],
        city: Optional[str],
        land_floor: float,
        number: int,
    ) -> Optional[str]:
        if search.sorted_by == "building_desc":
            areas = [r["building_m2"] for r in records if r.get("building_m2")]
            if areas and min(areas) < self.profile.building_floor:
                return None
        if search.sorted_by == "land_desc":
            areas = [r["land_m2"] for r in records if r.get("land_m2")]
            if areas and min(areas) < land_floor:
                return None
        # A selector the registry vouches for makes the hit count reliable enough to stop on.
        if search.hits and page.hits is not None:
            fetched = (number - search.page_first) * search.per_page + len(page.cards)
            if fetched >= page.hits:
                return None
        if not page.next_url and len(page.cards) < 0.8 * search.per_page:
            return None
        if search.paginates_by_url:
            return search.page_url(prefecture, city, self.profile.building_floor, land_floor, number + 1)
        return page.next_url if page.next_url and page.next_url.startswith("http") else None

    def _pages(
        self, source: Source, search: Search, key: str, prefecture: Optional[str], city: Optional[str], land_floor: float
    ) -> None:
        number = search.page_first
        url = search.page_url(prefecture, city, self.profile.building_floor, land_floor, number)
        for step in range(search.max_pages):
            out = self.ws.list_path(source.id, "%s-%s" % (search.listing_type, key), number)
            status, why = self._status(url, out)
            task = {
                "id": "list:%s:%s:%s:p%d" % (source.id, search.listing_type, key, number),
                "kind": "list",
                "source": source.id,
                "listing_type": search.listing_type,
                "host": _host(url),
                "url": url,
                "key": key,
                "page": number,
                "out": self.ws.relative(out),
                "status": status,
                "why": why,
                "extract": {"fn": "list", "card": search.card, "link": search.link, "hits": search.hits, "next": search.next},
            }
            self.tasks.append(task)
            if status != DONE:
                return
            page = pipeline.read_page(out)
            if page.status == pipeline.EMPTY:
                task["why"] = page.note
                return
            if page.status != pipeline.OK:
                task["status"], task["why"] = FAILED, page.note
                return
            found = pipeline.card_listings(self.ws, [page])
            records = list(found.values())
            task["cards"] = len(records)
            if not pipeline.page_is_parsed_well(page, records):
                task["status"], task["why"] = FAILED, "cards found but neither price nor area could be read: site markup changed"
                return
            if search.hits and page.hits is not None:
                # The registry vouches for this site's hit count, so a short page is a cut-off page.
                expected = max(0, min(search.per_page, page.hits - (number - search.page_first) * search.per_page))
                if len(page.cards) < 0.9 * expected:
                    task["status"] = FAILED
                    task["why"] = "page is incomplete: %d of %d cards arrived" % (len(page.cards), expected)
                    return
            for card_url, record in found.items():
                self.cards.setdefault(card_url, record)
            following = self._next_url(search, page, records, prefecture, city, land_floor, number)
            if following is None:
                return
            if step == search.max_pages - 1:
                task["truncated"] = True
                task["why"] = "stopped at the %d-page limit with more results remaining" % search.max_pages
                return
            number, url = number + 1, following

    def _search(self, source: Source, search: Search) -> None:
        profile = self.profile
        prefectures = [p for p in profile.areas if not search.prefectures or p in search.prefectures]
        if search.scope == "nationwide":
            loosest = min(z.land_m2_min for z in profile.zones) * profile.near_factor
            self._pages(source, search, "all", None, None, loosest)
            return
        for prefecture in prefectures:
            pref_slug = search.pref_slug(prefecture)
            if search.scope == "prefecture":
                self._pages(source, search, pref_slug, prefecture, None, profile.land_floor(prefecture))
                continue
            for city in self._cities(source, search, prefecture) or []:
                floor = profile.land_floor(prefecture, city["name"] or None)
                self._pages(source, search, "%s-%s" % (pref_slug, city["slug"]), prefecture, city["slug"], floor)

    # ------------------------------------------------------------ details

    def _details(self) -> None:
        profile = self.profile
        records, captures = pipeline.usable_details(self.ws, self.state, profile.detail_cache_days)
        merged = pipeline.merged_listings(self.cards, records, captures)
        live = [l for l in merged if criteria.judge(profile, l).status != criteria.REJECTED]
        wanted: List[Tuple[Tuple[int, float, str], Dict[str, Any]]] = []
        for group in dedupe.cluster(live):
            prop = dedupe.merge(group)
            if criteria.judge(profile, prop).status == criteria.REJECTED:
                continue
            if any(l.get("has_detail") and l.get("structure") for l in group):
                continue
            if sum(1 for l in group if l["url"] in captures) >= MAX_DETAIL_TRIES_PER_PROPERTY:
                continue
            untried = [l for l in group if l["url"] not in captures and not l.get("has_detail")]
            if not untried:
                continue
            pick = untried[0]
            priority = (0 if prop.get("concrete_hint") else 1, -(prop.get("building_m2") or 0.0), pick["url"])
            wanted.append((priority, pick))
        wanted.sort(key=lambda item: item[0])
        budget = max(0, profile.max_detail_pages - len(captures))

        for url, capture in sorted(captures.items()):
            self._detail_task(url, capture.record or self.cards.get(url) or {}, capture)
        for index, (_priority, listing) in enumerate(wanted):
            self._detail_task(listing["url"], listing, None, deferred=index >= budget)

    def _detail_task(
        self, url: str, listing: Dict[str, Any], capture: Optional[pipeline.DetailCapture], deferred: bool = False
    ) -> None:
        out = self.ws.detail_path(url)
        status, why = self._status(url, out)
        if capture is not None and capture.status != pipeline.OK:
            status, why = FAILED, capture.note
        elif status == TODO and deferred:
            status = DEFERRED
            why = "over this run's limit of %d detail pages; raise max_detail_pages or run again" % self.profile.max_detail_pages
        self.tasks.append(
            {
                "id": "detail:" + out.stem,
                "kind": "detail",
                "source": listing.get("source") or (self.cards.get(url) or {}).get("source"),
                "listing_type": listing.get("listing_type") or "used_house",
                "host": _host(url),
                "url": url,
                "out": self.ws.relative(out),
                "status": status,
                "why": why,
                "extract": {"fn": "detail"},
            }
        )

    def _hand_captures(self) -> None:
        """Result pages saved with `jpsearch add list`, which no planned search accounts for."""
        planned = {self.ws.home / t["out"] for t in self.tasks if t["kind"] == "list"}
        for page in pipeline.list_pages(self.ws):
            if page.path in planned:
                continue
            found = pipeline.card_listings(self.ws, [page]) if page.status == pipeline.OK else {}
            for url, record in found.items():
                self.cards.setdefault(url, record)
            url = page.task.get("url") or ""
            self.tasks.append(
                {
                    "id": "hand:" + page.path.stem,
                    "kind": "list",
                    "source": page.task.get("source"),
                    "listing_type": page.task.get("listing_type"),
                    "host": _host(url),
                    "url": url,
                    "out": self.ws.relative(page.path),
                    "status": DONE if page.status in (pipeline.OK, pipeline.EMPTY) else FAILED,
                    "why": page.note,
                    "by_hand": True,
                    "cards": len(found),
                    "extract": {"fn": "list"},
                }
            )

    # ------------------------------------------------------------ document

    def build(self) -> Dict[str, Any]:
        for source in self.sources:
            if not self._selected(source):
                continue
            for search in source.searches:
                if search.listing_type in self.profile.listing_types:
                    self._search(source, search)
        self._hand_captures()
        self._details()
        for task in self.tasks:
            task["delay_seconds"] = self._delay(task["host"])
        counts: Dict[str, int] = {}
        for task in self.tasks:
            counts[task["status"]] = counts.get(task["status"], 0) + 1
        return {
            "run": self.ws.run,
            "home": str(self.ws.home),
            "profile": self.profile.name,
            "counts": counts,
            "tasks": self.tasks,
        }


def _outcome(source: Optional[Source], tasks: List[Dict[str, Any]], skipped: bool, troubled: bool) -> str:
    planned = [t for t in tasks if t["kind"] == "list" and not t.get("by_hand")]
    if source is None or not source.searches:
        return "browsed by hand" if tasks else "manual"
    if skipped:
        return "skipped by profile"
    if not planned:
        return "not searched"
    if any(t["status"] in (TODO, WAITING) for t in tasks):
        return "incomplete"
    if all(t["status"] in (FAILED, DISALLOWED) for t in planned):
        return "failed"
    return "partial" if troubled else "searched"


def coverage(document: Dict[str, Any], sources: List[Source], profile: Profile) -> List[Dict[str, Any]]:
    """Per source: what was searched, what failed, and what a person still has to check by hand.

    Sources that appear only in hand-saved captures, and are not in the
    registry, get a row too, so nothing that fed the report goes unlisted.
    """
    by_source: Dict[str, List[Dict[str, Any]]] = {}
    for task in document["tasks"]:
        if task.get("source"):
            by_source.setdefault(task["source"], []).append(task)
    known = {s.id: s for s in sources}
    rows = []
    for source_id in list(known) + sorted(set(by_source) - set(known)):
        source = known.get(source_id)
        tasks = by_source.get(source_id, [])
        lists = [t for t in tasks if t["kind"] == "list"]
        details = [t for t in tasks if t["kind"] == "detail"]
        problems = sorted({t["why"] for t in tasks if t["status"] in (FAILED, DISALLOWED, DEFERRED) and t["why"]})
        truncated = [t["id"] for t in lists if t.get("truncated")]
        skipped = bool(profile.sources and source_id not in profile.sources) or source_id in profile.exclude_sources
        rows.append(
            {
                "id": source_id,
                "name": source.name if source else source_id,
                "kind": source.kind if source else "ad hoc",
                "home": source.home if source else next((t["url"] for t in tasks if t.get("url")), ""),
                "outcome": _outcome(source, tasks, skipped and source is not None, bool(problems or truncated)),
                "pages": sum(1 for t in lists if t["status"] == DONE),
                "pages_failed": sum(1 for t in lists if t["status"] == FAILED),
                "pages_disallowed": sum(1 for t in lists if t["status"] == DISALLOWED),
                "cards": sum(t.get("cards", 0) for t in lists),
                "details": sum(1 for t in details if t["status"] == DONE),
                "truncated": truncated,
                "problems": problems,
                "manual": source.manual if source else "",
            }
        )
    return rows
