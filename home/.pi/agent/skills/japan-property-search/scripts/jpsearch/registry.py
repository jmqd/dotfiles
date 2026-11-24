"""The source registry: which sites exist and how each one is searched.

references/sources.json is data, edited as sites change. This module parses
it into typed records and rejects entries the planner could not act on, so a
typo in the registry fails at load time and not halfway through a run.
"""

from __future__ import annotations

import json
import re
import string
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote, urlsplit

import text

_REFERENCES = Path(__file__).resolve().parent.parent.parent / "references"
# The shipped registry: sites this tool can search, and sites a person browses.
REGISTRY_PATHS = (_REFERENCES / "sources.json", _REFERENCES / "sources-manual.json")
PREF_FORMATS = ("romaji", "code", "ja", "slugs")

SCOPES = ("nationwide", "prefecture", "city")
SORTS = ("building_desc", "land_desc", None)
KINDS = ("portal", "aggregator", "broker", "luxury", "english", "design", "resort", "rural", "auction")
# ok: an automated browser can read it. partial: some pages or filters only.
# blocked: it challenges automated browsers. disallowed: robots.txt keeps this
# toolkit out. unverified: never loaded.
ACCESS = ("ok", "partial", "blocked", "disallowed", "unverified")
_URL_FIELDS = {"pref", "city", "cities", "building_min", "land_min", "page", "offset"}


class RegistryError(ValueError):
    """references/sources.json holds an entry the planner cannot use."""


def _template_fields(template: str) -> set:
    return {name for _lit, name, _spec, _conv in string.Formatter().parse(template) if name}


@dataclass(frozen=True)
class Minimum:
    """What a site accepts for a minimum-area filter.

    `options` lists the only values it takes; `free` means any number, up to
    `cap` when the site rejects larger ones. Neither means it has no filter.
    """

    options: Optional[Tuple[int, ...]] = None
    free: bool = False
    cap: Optional[int] = None

    def for_floor(self, floor: float) -> int:
        """The tightest value the site accepts that cannot hide a listing at or above `floor`."""
        if self.free:
            return int(min(floor, self.cap)) if self.cap is not None else int(floor)
        if not self.options:
            return 0
        usable = [o for o in self.options if o <= floor]
        return max(usable) if usable else min(self.options)


@dataclass(frozen=True)
class Discover:
    """How to list a prefecture's municipalities on a site that needs them named.

    `link` is a regular expression over link URLs whose first group is the
    municipality's slug; `inputs` is a CSS selector for form controls whose
    value is its code. Exactly one is set.
    """

    url: str
    link: Optional["re.Pattern[str]"]
    inputs: Optional[str]


@dataclass(frozen=True)
class Search:
    listing_type: str
    scope: str
    url: str
    pref_format: str
    pref_slugs: Dict[str, str]
    prefectures: Tuple[str, ...]
    building_min: Minimum
    land_min: Minimum
    fixed_building_min: int
    sorted_by: Optional[str]
    per_page: int
    page_first: int
    max_pages: int
    cities_param: Optional[str]
    cities_per_url: int
    card: Optional[str]
    link: Optional[str]
    hits: Optional[str]
    next: Optional[str]
    discover: Optional[Discover]

    def pref_slug(self, prefecture: str) -> str:
        if prefecture in self.pref_slugs:
            return self.pref_slugs[prefecture]
        if self.pref_format == "code":
            return "%02d" % (text.PREFECTURES.index(prefecture) + 1)
        if self.pref_format == "ja":
            return quote(prefecture)
        return text.PREF_ROMAJI[prefecture].lower()

    def page_url(
        self,
        prefecture: Optional[str],
        city: Optional[str],
        building_floor: float,
        land_floor: float,
        page: int,
        cities: Tuple[str, ...] = (),
    ) -> str:
        lead, listed = city or "", cities
        if cities and "city" in _template_fields(self.url):
            # The URL names one municipality in its path and the others in a parameter.
            lead, listed = cities[0], cities[1:]
        if self.cities_param:
            joined = "&".join("%s=%s" % (self.cities_param, code) for code in listed)
        else:
            joined = ",".join(listed)
        values = {
            "pref": self.pref_slug(prefecture) if prefecture else "",
            "city": lead,
            "cities": joined,
            "building_min": self.building_min.for_floor(building_floor),
            "land_min": self.land_min.for_floor(land_floor),
            "page": page,
            "offset": (page - self.page_first) * self.per_page,
        }
        return self.url.format(**values)

    @property
    def paginates_by_url(self) -> bool:
        return bool(_template_fields(self.url) & {"page", "offset"})

    @property
    def names_cities(self) -> bool:
        """True when one URL covers a prefecture only by listing its municipalities."""
        return "cities" in _template_fields(self.url)


@dataclass(frozen=True)
class Source:
    """One site. `searches` is empty for a site that is browsed by hand, as `manual` describes."""

    id: str
    name: str
    name_ja: str
    kind: str
    coverage: str
    areas: Tuple[str, ...]
    home: str
    verified: str
    access: str
    rank: int
    notes: str
    manual: str
    photo_rule: str
    searches: Tuple[Search, ...]

    @property
    def host(self) -> str:
        return urlsplit(self.home).hostname or ""

    def covers(self, prefectures: Tuple[str, ...]) -> bool:
        """True when the site lists property in any of `prefectures`. No stated areas means nationwide."""
        return not self.areas or any(p in self.areas for p in prefectures)


def _minimum(raw: Any, where: str) -> Minimum:
    if raw is None:
        return Minimum()
    if raw == "free":
        return Minimum(free=True)
    if isinstance(raw, dict) and isinstance(raw.get("free_up_to"), int) and len(raw) == 1:
        return Minimum(free=True, cap=raw["free_up_to"])
    if isinstance(raw, list) and raw and all(isinstance(v, int) and not isinstance(v, bool) for v in raw):
        return Minimum(options=tuple(sorted(raw)))
    raise RegistryError('%s must be null, "free", {"free_up_to": N} or a list of integers' % where)


def _prefectures(items: Any, where: str) -> List[str]:
    out = []
    for item in items or []:
        address = text.parse_address(str(item))
        if address.prefecture is None:
            raise RegistryError("%s entry is not a prefecture: %r" % (where, item))
        out.append(address.prefecture)
    return out


def _discover(raw: Any, where: str) -> Discover:
    if not isinstance(raw, dict) or not isinstance(raw.get("url"), str):
        raise RegistryError("%s needs discover.url" % where)
    link, inputs = raw.get("link"), raw.get("inputs")
    if (link is None) == (inputs is None):
        raise RegistryError("%s.discover needs exactly one of 'link' and 'inputs'" % where)
    pattern = None
    if link is not None:
        try:
            pattern = re.compile(link)
        except re.error as exc:
            raise RegistryError("%s.discover.link is not a valid regex: %s" % (where, exc)) from exc
        if pattern.groups < 1:
            raise RegistryError("%s.discover.link needs one capture group for the municipality" % where)
    return Discover(raw["url"], pattern, inputs)


def _search(source_id: str, index: int, raw: Dict[str, Any]) -> Search:
    where = "%s.searches[%d]" % (source_id, index)
    for key in ("listing_type", "scope", "url"):
        if not isinstance(raw.get(key), str):
            raise RegistryError("%s is missing '%s'" % (where, key))
    scope = raw["scope"]
    if scope not in SCOPES:
        raise RegistryError("%s.scope must be one of %s" % (where, ", ".join(SCOPES)))
    fields = _template_fields(raw["url"])
    if fields - _URL_FIELDS:
        raise RegistryError("%s.url has unknown placeholders %s" % (where, sorted(fields - _URL_FIELDS)))
    if scope == "city" and "city" not in fields:
        raise RegistryError("%s.url needs {city} for city scope" % where)
    if scope == "prefecture" and "pref" not in fields:
        raise RegistryError("%s.url needs {pref} for prefecture scope" % where)
    if "cities" in fields and scope != "prefecture":
        raise RegistryError("%s: {cities} needs prefecture scope" % where)
    sorted_by = raw.get("sorted_by")
    if sorted_by not in SORTS:
        raise RegistryError("%s.sorted_by must be building_desc, land_desc or null" % where)
    needs_discover = scope == "city" or "cities" in fields
    if needs_discover and "discover" not in raw:
        raise RegistryError("%s needs 'discover' to learn the municipalities" % where)
    hints = raw.get("hints") or {}
    pref_slugs = {}
    for name, slug in (raw.get("pref_slugs") or {}).items():
        pref_slugs[_prefectures([name], where + ".pref_slugs")[0]] = slug
    pref_format = raw.get("pref_format", "romaji")
    if pref_format not in PREF_FORMATS:
        raise RegistryError("%s.pref_format must be one of %s" % (where, ", ".join(PREF_FORMATS)))
    prefectures = tuple(_prefectures(raw.get("prefectures"), where + ".prefectures"))
    if pref_format == "slugs" and "pref" in fields:
        # The site's own codes cannot be derived, so every prefecture the search may be asked for needs one.
        missing = [p for p in prefectures or text.PREFECTURES if p not in pref_slugs]
        if missing:
            raise RegistryError("%s.pref_slugs lacks %s" % (where, ", ".join(missing)))
    return Search(
        listing_type=raw["listing_type"],
        scope=scope,
        url=raw["url"],
        pref_format=pref_format,
        pref_slugs=pref_slugs,
        prefectures=prefectures,
        building_min=_minimum(raw.get("building_min"), where + ".building_min"),
        land_min=_minimum(raw.get("land_min"), where + ".land_min"),
        fixed_building_min=int(raw.get("fixed_building_min", 0)),
        sorted_by=sorted_by,
        per_page=int(raw.get("per_page", 20)),
        page_first=int(raw.get("page_first", 1)),
        max_pages=int(raw.get("max_pages", 20)),
        cities_param=raw.get("cities_param"),
        cities_per_url=int(raw.get("cities_per_url", 60)),
        card=hints.get("card"),
        link=hints.get("link"),
        hits=hints.get("hits"),
        next=hints.get("next"),
        discover=_discover(raw["discover"], where) if needs_discover else None,
    )


def parse_registry(data: Any) -> List[Source]:
    if not isinstance(data, dict) or not isinstance(data.get("sources"), list):
        raise RegistryError("registry must be an object with a 'sources' list")
    sources = []
    seen = set()
    for raw in data["sources"]:
        for key in ("id", "name", "kind", "home"):
            if not isinstance(raw.get(key), str) or not raw[key]:
                raise RegistryError("source %r is missing '%s'" % (raw.get("id"), key))
        where = "source %s" % raw["id"]
        if raw["id"] in seen:
            raise RegistryError("duplicate source id %s" % raw["id"])
        seen.add(raw["id"])
        if raw["kind"] not in KINDS:
            raise RegistryError("%s: kind must be one of %s" % (where, ", ".join(KINDS)))
        access = raw.get("access") or "unverified"
        if access not in ACCESS:
            raise RegistryError("%s: access must be one of %s" % (where, ", ".join(ACCESS)))
        rank = raw.get("rank", 3)
        if not isinstance(rank, int) or isinstance(rank, bool) or not 1 <= rank <= 5:
            raise RegistryError("%s: rank must be 1 (most productive) to 5" % where)
        searches = tuple(_search(raw["id"], i, s) for i, s in enumerate(raw.get("searches") or []))
        sources.append(
            Source(
                id=raw["id"],
                name=raw["name"],
                name_ja=raw.get("name_ja") or raw["name"],
                kind=raw["kind"],
                coverage=raw.get("coverage") or "",
                areas=tuple(_prefectures(raw.get("areas"), where + ".areas")),
                home=raw["home"],
                verified=raw.get("verified") or "",
                access=access,
                rank=rank,
                notes=raw.get("notes") or "",
                manual=raw.get("manual") or "",
                photo_rule=raw.get("photo_rule") or "",
                searches=searches,
            )
        )
    return sources


def _read(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RegistryError("%s is not valid JSON: %s" % (path, exc)) from exc
    if not isinstance(data, dict) or not isinstance(data.get("sources"), list):
        raise RegistryError("%s must be an object with a 'sources' list" % path)
    if not all(isinstance(raw, dict) for raw in data["sources"]):
        raise RegistryError("%s: every source must be an object" % path)
    ids = [raw.get("id") for raw in data["sources"]]
    twice = next((i for i in ids if ids.count(i) > 1), None)
    if twice is not None:
        raise RegistryError("%s lists source %r twice" % (path, twice))
    return data


def load_registry(paths: Tuple[Path, ...] = REGISTRY_PATHS, overlay: Optional[Path] = None) -> List[Source]:
    """The shipped registry files, with the workspace's own entries laid over them.

    `overlay` is a file of the same form kept in the workspace. An entry
    there replaces the shipped entry with the same id, and a new id is added,
    so a site can be fixed or added without touching the skill.
    """
    entries: Dict[Any, Dict[str, Any]] = {}
    for path in paths:
        for raw in _read(path)["sources"]:
            if raw.get("id") in entries:
                raise RegistryError("%s lists source %r, which another registry file already holds" % (path, raw.get("id")))
            entries[raw.get("id")] = raw
    if overlay is not None and overlay.exists():
        for raw in _read(overlay)["sources"]:
            entries[raw.get("id")] = raw
    return parse_registry({"sources": list(entries.values())})
