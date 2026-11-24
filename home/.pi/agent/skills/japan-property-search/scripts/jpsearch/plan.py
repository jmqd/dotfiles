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
import pipeline
import robots
import text
from criteria import Profile
from registry import Discover, Search, Source
from workspace import Workspace, read_json, write_json

TODO, DONE, FAILED, DISALLOWED, WAITING, DEFERRED = "todo", "done", "failed", "disallowed", "waiting", "deferred"
# The site answered, and said the listing is no longer there.
GONE = "gone"
# A search the registry holds but this profile cannot use.
SKIPPED = "skipped"

DISCOVER_CACHE_DAYS = 30
MAX_DETAIL_TRIES_PER_PROPERTY = 3
# A page that failed to load (a timeout, a dropped connection) is fetched once more in the same run.
MAX_ATTEMPTS = 2


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


def parse_cities(envelope: Dict[str, Any], discover: Discover) -> List[Dict[str, Any]]:
    """Municipalities from a captured index page: [{slug, name, count}], count None when not shown.

    Links yield the slug their URL carries; form controls yield their value,
    which is the municipality's code.
    """
    result = envelope.get("result") or {}
    cities: Dict[str, Dict[str, Any]] = {}
    if discover.link is not None:
        found = []
        for item in result.get("links") or []:
            m = discover.link.search(item.get("href") or "")
            if m:
                found.append((m.group(1), item.get("text") or ""))
    else:
        # Group boxes ("all 23 wards") carry values such as "on", not a code.
        found = [(i.get("value") or "", i.get("text") or "") for i in result.get("inputs") or [] if re.fullmatch(r"\d{4,6}", i.get("value") or "")]
    for slug, raw_label in found:
        # Folded first, so full-width digits and brackets read like ASCII ones.
        label = re.sub(r"\s+", " ", text.nfkc(raw_label)).strip()
        # The listing count beside a name comes as (12), 12件 or a bare 12.
        count_match = re.search(r"\(\s*([\d,]+)\s*\)|([\d,]+)\s*件|\s([\d,]+)$", label)
        count = int(next(g for g in count_match.groups() if g).replace(",", "")) if count_match else None
        name = re.sub(r"\(.*$|[\d,]+\s*件.*$|\s[\d,]+$", "", label).strip()
        if slug not in cities or (not cities[slug]["name"] and name):
            cities[slug] = {"slug": slug, "name": name, "count": count}
    return [c for c in cities.values() if c["count"] != 0]


def sorted_backbone(values: List[float]) -> List[float]:
    """The longest run of `values`, in page order, that never rises.

    A results page sorted largest-first also carries promoted cards that
    ignore the sort. They break the descending order, so they fall outside
    this run and cannot be mistaken for the point where the list has passed
    a threshold.
    """
    if not values:
        return []
    best_len = [1] * len(values)
    previous = [-1] * len(values)
    for i in range(len(values)):
        for j in range(i):
            if values[j] >= values[i] and best_len[j] + 1 > best_len[i]:
                best_len[i], previous[i] = best_len[j] + 1, j
    end = max(range(len(values)), key=lambda i: (best_len[i], i))
    run = []
    while end != -1:
        run.append(values[end])
        end = previous[end]
    return run[::-1]


def passed_floor(values: List[float], floor: float) -> bool:
    """True when a largest-first page has run below `floor`: its last two in-order values are under it."""
    tail = sorted_backbone(values)[-2:]
    return bool(tail) and all(v < floor for v in tail)


class Planner:
    def __init__(
        self, ws: Workspace, profile: Profile, sources: List[Source], state: Dict[str, Any], retry_failed: bool = False
    ) -> None:
        """`retry_failed` queues every page whose load failed again, however often it was tried."""
        self.ws = ws
        self.profile = profile
        self.sources = sources
        self.state = state
        self.retry_failed = retry_failed
        self.tasks: List[Dict[str, Any]] = []
        self.cards: Dict[str, Dict[str, Any]] = {}
        self._robots: Dict[str, RobotsVerdict] = {}

    def _next_attempt(self, envelope: Optional[Dict[str, Any]]) -> Optional[int]:
        """The number of the next try when a capture failed to load and may be fetched again, else None.

        Only load errors qualify. A page that loaded and showed a block page
        or unreadable markup would show the same again.
        """
        if not envelope or not envelope.get("error"):
            return None
        tried = int(envelope.get("attempt") or 1)
        return tried + 1 if self.retry_failed or tried < MAX_ATTEMPTS else None

    # ------------------------------------------------------------ robots

    def _verdict(self, url: str) -> RobotsVerdict:
        parts = urlsplit(url)
        host = parts.hostname or ""
        if host not in self._robots:
            path = self.ws.robots_path(host)
            envelope = read_json(path)
            attempt = self._next_attempt(envelope)
            if attempt is not None:
                verdict = RobotsVerdict("pending", None, "retrying robots.txt after: %s" % str(envelope["error"])[:120])
            else:
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
                    "status": TODO if verdict.state == "pending" else DONE,
                    "why": verdict.note,
                    "attempt": attempt or 1,
                    "extract": {"fn": "robots"},
                }
            )
        return self._robots[host]

    def _status(self, url: str, out: Path) -> Tuple[str, str, int]:
        """(status, why, attempt) for fetching `url` into `out`; `attempt` numbers the try a `todo` stands for."""
        verdict = self._verdict(url)
        attempt, why = 1, ""
        if out.exists():
            envelope = read_json(out) or {}
            if (envelope.get("task") or {}).get("url") not in (None, url):
                # The file answers another question: the profile or the registry was edited and the
                # search's URL changed. Read as it stands, it would pass for this search's results.
                why = "the search changed since this page was read"
            else:
                retry = self._next_attempt(envelope)
                if retry is None:
                    return DONE, "", int(envelope.get("attempt") or 1)
                attempt, why = retry, "retrying after: %s" % str(envelope["error"])[:120]
        if verdict.state == "pending":
            return WAITING, "waiting for robots.txt", attempt
        if verdict.state == "closed":
            return DISALLOWED, verdict.note, attempt
        if verdict.state == "rules" and not robots.allowed(verdict.rules, url):
            return DISALLOWED, "robots.txt disallows this URL", attempt
        return TODO, why, attempt

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
        assert search.discover is not None, "the registry guarantees discover wherever municipalities are needed"
        discover = search.discover
        pref_slug = search.pref_slug(prefecture)
        cache_path = self.ws.discover_cache_path(source.id, search.listing_type, pref_slug)
        cached = read_json(cache_path)
        if cached and _fresh(cached["fetched"], self.ws.run_date, DISCOVER_CACHE_DAYS):
            return cached["cities"]
        url = discover.url.format(pref=pref_slug)
        out = self.ws.discover_run_path(source.id, "%s-%s" % (search.listing_type, pref_slug))
        status, why, attempt = self._status(url, out)
        cities = None
        if status == DONE:
            envelope = read_json(out) or {}
            if envelope.get("error"):
                status, why = FAILED, str(envelope["error"])[:200]
            else:
                cities = parse_cities(envelope, discover)
                if cities:
                    write_json(cache_path, {"fetched": self.ws.run_date, "url": url, "cities": cities})
                else:
                    status, why, cities = FAILED, "no municipalities found on the index page: site markup changed", None
        if discover.link is not None:
            extract = {"fn": "links", "pattern": discover.link.pattern}
        else:
            extract = {"fn": "inputs", "selector": discover.inputs}
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
                "attempt": attempt,
                "extract": extract,
            }
        )
        return cities

    def _wants_next(self, search: Search, page: pipeline.Page, records: List[Dict[str, Any]], land_floor: float, number: int) -> bool:
        if search.sorted_by == "building_desc" and passed_floor(
            [r["building_m2"] for r in records if r.get("building_m2")], self.profile.building_floor
        ):
            return False
        if search.sorted_by == "land_desc" and passed_floor([r["land_m2"] for r in records if r.get("land_m2")], land_floor):
            return False
        # A selector the registry vouches for makes the hit count reliable enough to stop on.
        if search.hits and page.hits is not None:
            fetched = (number - search.page_first) * search.per_page + len(page.cards)
            if fetched >= page.hits:
                return False
        return bool(page.next_url) or len(page.cards) >= 0.8 * search.per_page

    def _pages(
        self,
        source: Source,
        search: Search,
        key: str,
        prefecture: Optional[str],
        city: Optional[str],
        land_floor: float,
        cities: Tuple[str, ...] = (),
    ) -> None:
        def address(page_number: int) -> str:
            return search.page_url(prefecture, city, self.profile.building_floor, land_floor, page_number, cities)

        number = search.page_first
        url = address(number)
        seen_here: set = set()
        for step in range(search.max_pages):
            out = self.ws.list_path(source.id, "%s-%s" % (search.listing_type, key), number)
            status, why, attempt = self._status(url, out)
            task = {
                "id": "list:%s:%s:%s:p%d" % (source.id, search.listing_type, key, number),
                "kind": "list",
                "source": source.id,
                "listing_type": search.listing_type,
                "host": _host(url),
                "url": url,
                "key": key,
                "page": number,
                "prefecture": prefecture,
                "out": self.ws.relative(out),
                "status": status,
                "why": why,
                "attempt": attempt,
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
                    task["why"] = "page is incomplete: %d of %d cards arrived" % (len(page.cards), expected)
                    # A page cut short while loading is a failed load like any other: fetch it once more.
                    again = self.retry_failed or attempt < MAX_ATTEMPTS
                    task["status"], task["attempt"] = (TODO, attempt + 1) if again else (FAILED, attempt)
                    return
            if seen_here and not set(found) - seen_here:
                # A site that clamps the page number serves its last page again; without this the search would run to the page limit.
                task["why"] = "page repeats earlier results: the list has ended"
                return
            seen_here.update(found)
            for card_url, record in found.items():
                self.cards.setdefault(card_url, record)
            if not self._wants_next(search, page, records, land_floor, number):
                return
            following = address(number + 1) if search.paginates_by_url else page.next_url
            if not following or not following.startswith("http"):
                return
            if step == search.max_pages - 1:
                task["truncated"] = True
                task["why"] = "stopped at the %d-page limit with more results remaining" % search.max_pages
                return
            number, url = number + 1, following

    def _search(self, source: Source, search: Search) -> None:
        profile = self.profile
        if search.fixed_building_min > profile.building_floor:
            # The site's URL can only ask for buildings above a fixed size; using it would hide smaller ones the profile wants.
            self.tasks.append(
                {
                    "id": "list:%s:%s:skipped" % (source.id, search.listing_type),
                    "kind": "list",
                    "source": source.id,
                    "listing_type": search.listing_type,
                    "host": source.host,
                    "url": source.home,
                    "out": "",
                    "status": SKIPPED,
                    "why": "its search only returns buildings of %d m² or more, which is above this profile's minimum; browse it by hand"
                    % search.fixed_building_min,
                }
            )
            return
        prefectures = [p for p in profile.areas if not search.prefectures or p in search.prefectures]
        if search.scope == "nationwide":
            loosest = min(z.land_m2_min for z in profile.zones) * profile.near_factor
            self._pages(source, search, "all", None, None, loosest)
            return
        for prefecture in prefectures:
            pref_slug = search.pref_slug(prefecture)
            if search.scope == "prefecture" and not search.names_cities:
                self._pages(source, search, pref_slug, prefecture, None, profile.land_floor(prefecture))
                continue
            found = self._cities(source, search, prefecture) or []
            if search.scope == "city":
                for city in found:
                    floor = profile.land_floor(prefecture, city["name"] or None)
                    self._pages(source, search, "%s-%s" % (pref_slug, city["slug"]), prefecture, city["slug"], floor)
                continue
            # One URL covers the prefecture by naming its municipalities; long lists are split.
            codes = [c["slug"] for c in found]
            for start in range(0, len(codes), search.cities_per_url):
                chunk = tuple(codes[start : start + search.cities_per_url])
                key = "%s-%d" % (pref_slug, start // search.cities_per_url + 1)
                self._pages(source, search, key, prefecture, None, profile.land_floor(prefecture), chunk)

    # ------------------------------------------------------------ details

    def _details(self) -> None:
        """Queue the detail page of every property that the cards alone neither confirm nor rule out.

        Listings are grouped into properties first, so what one agent's
        card or page states (a wooden structure, say) settles the question
        for every other listing of the same house.
        """
        profile = self.profile
        records, captures = pipeline.usable_details(self.ws, self.state, profile.detail_cache_days)
        merged = pipeline.merged_listings(self.cards, records, captures)
        wanted: List[Tuple[Tuple[int, float, str], Dict[str, Any]]] = []
        for judged in pipeline.judged_properties(profile, merged):
            prop, group = judged.prop, judged.listings
            if judged.verdict.status == criteria.REJECTED:
                continue
            if prop["has_detail"] and prop.get("structure"):
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
        status, why, attempt = self._status(url, out)
        if status == DONE and capture is not None and capture.status == pipeline.GONE:
            status, why = GONE, capture.note
        elif status == DONE and capture is not None and capture.status != pipeline.OK:
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
                "attempt": attempt,
                "extract": {"fn": "detail"},
            }
        )

    def _hand_captures(self) -> None:
        """Result pages saved with `jpsearch add list`, which no planned search accounts for.

        A planned page that the plan no longer asks for (the profile or the
        registry changed during the run) is left out: it answers a search
        nobody is running.
        """
        planned = {self.ws.home / t["out"] for t in self.tasks if t["kind"] == "list"}
        for page in pipeline.list_pages(self.ws):
            if page.path in planned or not page.task.get("by_hand"):
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
        return "no search for these areas"
    if all(t["status"] == SKIPPED for t in planned):
        return "not applicable"
    if any(t["status"] in (TODO, WAITING) for t in tasks):
        return "incomplete"
    if all(t["status"] in (FAILED, DISALLOWED) for t in planned):
        return "failed"
    return "partial" if troubled else "searched"


def _problems(tasks: List[Dict[str, Any]]) -> List[str]:
    """What went wrong on a source, each distinct reason once with how many pages it hit."""
    counts: Dict[str, int] = {}
    for task in tasks:
        if task["status"] in (FAILED, DISALLOWED, SKIPPED) and task["why"]:
            counts[task["why"]] = counts.get(task["why"], 0) + 1
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return ["%s (%d page%s)" % (why, n, "" if n == 1 else "s") if n > 1 else why for why, n in ordered]


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
        problems = _problems(tasks)
        truncated = [t["id"] for t in lists if t.get("truncated")]
        deferred = sum(1 for t in details if t["status"] == DEFERRED)
        skipped = bool(profile.sources and source_id not in profile.sources) or source_id in profile.exclude_sources
        rows.append(
            {
                "id": source_id,
                "name": source.name if source else source_id,
                "kind": source.kind if source else "ad hoc",
                "home": source.home if source else next((t["url"] for t in tasks if t.get("url")), ""),
                "access": source.access if source else "",
                "rank": source.rank if source else 3,
                "covers_profile": source.covers(profile.areas) if source else True,
                "outcome": _outcome(source, tasks, skipped and source is not None, bool(problems or truncated or deferred)),
                "pages": sum(1 for t in lists if t["status"] == DONE),
                "pages_failed": sum(1 for t in lists if t["status"] == FAILED),
                "pages_disallowed": sum(1 for t in lists if t["status"] == DISALLOWED),
                "cards": sum(t.get("cards", 0) for t in lists),
                "details": sum(1 for t in details if t["status"] == DONE),
                "details_failed": sum(1 for t in details if t["status"] == FAILED),
                "details_gone": sum(1 for t in details if t["status"] == GONE),
                "details_deferred": deferred,
                "details_unread": sum(1 for t in details if t["status"] in (TODO, WAITING)),
                "truncated": truncated,
                "problems": problems,
            }
        )
    return rows
