"""Group listings of the same property.

One house is commonly advertised by several agents on one portal and again
on other portals, each with its own title and sometimes its own price. The
physical facts agree, so listings are matched on location, areas and build
date, never on title or URL.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from typing import Any, Dict, List, Optional, Tuple

import text

Listing = Dict[str, Any]


def _close(a: Optional[float], b: Optional[float], absolute: float, relative: float) -> Optional[bool]:
    """Whether two measurements agree; None when either is missing."""
    if a is None or b is None:
        return None
    return abs(a - b) <= max(absolute, relative * max(a, b))


def _split_town(town: Optional[str]) -> Tuple[str, Optional[str]]:
    m = re.match(r"(.*?)(\d+)$", town or "")
    if m:
        return m.group(1), m.group(2)
    return town or "", None


def towns_compatible(a: Optional[str], b: Optional[str]) -> bool:
    """False only when both towns are stated and they contradict each other."""
    base_a, num_a = _split_town(a)
    base_b, num_b = _split_town(b)
    if base_a and base_b and not (base_a.startswith(base_b) or base_b.startswith(base_a)):
        return False
    if num_a and num_b and num_a != num_b and base_a == base_b:
        return False
    return True


def same_property(a: Listing, b: Listing) -> Optional[str]:
    """The reason two listings are one property, or None when they are not shown to be."""
    if a.get("listing_type") != b.get("listing_type"):
        return None
    if a.get("prefecture") and b.get("prefecture") and a["prefecture"] != b["prefecture"]:
        return None
    key_a = text.municipality_key(a.get("municipality"))
    key_b = text.municipality_key(b.get("municipality"))
    if key_a and key_b and not (key_a.startswith(key_b) or key_b.startswith(key_a)):
        return None
    if not towns_compatible(a.get("town"), b.get("town")):
        return None

    land = _close(a.get("land_m2"), b.get("land_m2"), 0.6, 0.003)
    building = _close(a.get("building_m2"), b.get("building_m2"), 0.6, 0.003)
    price = _close(a.get("price_jpy"), b.get("price_jpy"), 0, 0.005)
    built = None
    if a.get("built_year") and b.get("built_year"):
        built = a["built_year"] == b["built_year"]
        if built and a.get("built_month") and b.get("built_month"):
            built = a["built_month"] == b["built_month"]

    if land and building and built is not False:
        return "same land and building area"
    if land and built and price:
        return "same land area, build date and price"
    if building and built and price and land is not False:
        return "same building area, build date and price"
    same_town = bool(a.get("town")) and a.get("town") == b.get("town") and bool(key_a) and key_a == key_b
    if same_town and land and price:
        # Agents copy the lot and the price faithfully and are careless with the rest: one house
        # was listed with two floor areas and two build years. In one chome, the same lot at the
        # same price is the same house.
        return "same town, land area and price"
    return None


class _Sets:
    def __init__(self, n: int) -> None:
        self.parent = list(range(n))

    def find(self, i: int) -> int:
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, i: int, j: int) -> None:
        self.parent[self.find(j)] = self.find(i)


def cluster(listings: List[Listing]) -> List[List[Listing]]:
    """Listings grouped by property. Order within and between groups is deterministic."""
    listings = sorted(listings, key=lambda l: (l.get("source") or "", l.get("url") or ""))
    sets = _Sets(len(listings))
    by_prefecture: Dict[str, List[int]] = {}
    for i, listing in enumerate(listings):
        by_prefecture.setdefault(listing.get("prefecture") or "", []).append(i)
    # Listings whose prefecture is unknown are compared against everything.
    loose = by_prefecture.pop("", [])
    for candidates in [members + loose for members in by_prefecture.values()] or [loose]:
        for x in range(len(candidates)):
            for y in range(x + 1, len(candidates)):
                i, j = candidates[x], candidates[y]
                if sets.find(i) != sets.find(j) and same_property(listings[i], listings[j]):
                    sets.union(i, j)
    groups: Dict[int, List[Listing]] = {}
    for i, listing in enumerate(listings):
        groups.setdefault(sets.find(i), []).append(listing)
    return sorted(groups.values(), key=lambda g: g[0].get("url") or "")


def _mode(values: List[Any]) -> Any:
    present = [v for v in values if v not in (None, "", [])]
    if not present:
        return None
    counts = Counter(repr(v) for v in present)
    best = max(counts.values())
    for v in present:
        if counts[repr(v)] == best:
            return v
    return None


def _first(values: List[Any]) -> Any:
    return next((v for v in values if v not in (None, "", [])), None)


def property_id(prop: Dict[str, Any]) -> str:
    """A short id derived from the property's physical facts."""
    basis = "|".join(
        str(x)
        for x in (
            prop.get("prefecture"),
            text.municipality_key(prop.get("municipality")),
            round(prop["land_m2"], 1) if prop.get("land_m2") else None,
            round(prop["building_m2"], 1) if prop.get("building_m2") else None,
            prop.get("built_year"),
            None if prop.get("land_m2") or prop.get("building_m2") else prop.get("urls", [""])[0],
        )
    )
    return "p" + hashlib.sha1(basis.encode("utf-8")).hexdigest()[:7]


def _structure_statements(ranked: List[Listing]) -> List[Listing]:
    """One listing for each distinct structure the group states, most complete listing first.

    その他 ("other") says nothing once another listing names the material.
    """
    stated: Dict[Tuple[str, Tuple[str, ...]], Listing] = {}
    for listing in ranked:
        if listing.get("structure"):
            stated.setdefault((listing["structure"], tuple(listing.get("structure_parts") or [])), listing)
    named = [l for l in stated.values() if l["structure"] != text.OTHER]
    return named or list(stated.values())


def merge(group: List[Listing]) -> Dict[str, Any]:
    """One property record from the listings that advertise it.

    Measurements take the value most listings agree on. Descriptive fields
    come from the most complete listing, preferring ones whose detail page
    was read. Where listings state different structures, all of them are
    kept in `structure_variants` for the criteria to weigh.
    """
    ranked = sorted(
        group,
        key=lambda l: (not l.get("has_detail"), -sum(1 for v in l.values() if v not in (None, "", [])), l.get("url") or ""),
    )
    prices = sorted(l["price_jpy"] for l in group if l.get("price_jpy"))
    prop: Dict[str, Any] = {}
    for field in ("land_m2", "building_m2", "built_year", "built_month", "prefecture", "municipality", "layout", "listing_type"):
        prop[field] = _mode([l.get(field) for l in ranked])
    for field in (
        "title", "address", "town", "access", "land_right", "zoning",
        "coverage_far", "far", "road", "land_category", "city_planning", "status", "handover", "restrictions",
        "remarks", "renovation", "villa_estate", "water", "sewer", "gas", "hot_spring", "management_fee",
        "altitude", "image", "coords", "land_basis", "building_basis", "kind",
    ):
        prop[field] = _first([l.get(field) for l in ranked])
    statements = _structure_statements(ranked)
    lead = statements[0] if statements else {}
    prop["structure"] = lead.get("structure")
    prop["structure_parts"] = list(lead.get("structure_parts") or [])
    prop["structure_text"] = lead.get("structure_text")
    prop["structure_variants"] = (
        [{"kind": l["structure"], "parts": list(l.get("structure_parts") or []), "text": l.get("structure_text") or l["structure"]} for l in statements]
        if len(statements) > 1
        else []
    )
    for field in ("floors", "basement"):
        prop[field] = _first([lead.get(field)] + [l.get(field) for l in ranked])
    prop["built_approximate"] = all(l.get("built_approximate") for l in group if l.get("built_year")) and any(
        l.get("built_year") for l in group
    )
    prop["concrete_hint"] = any(l.get("concrete_hint") for l in group)
    prop["price_jpy"] = prices[0] if prices else None
    prop["price_max_jpy"] = prices[-1] if prices and prices[-1] != prices[0] else None
    prop["price_undisclosed"] = not prices and any(l.get("price_undisclosed") for l in group)
    prop["flags"] = sorted({f for l in group for f in l.get("flags") or []})
    prop["has_detail"] = any(l.get("has_detail") for l in group)
    prop["image_count"] = max((l.get("image_count") or 0 for l in group), default=0)
    for field in ("building_m2", "land_m2"):
        stated = sorted({l[field] for l in group if l.get(field)})
        if len(stated) > 1:
            prop[field + "_variants"] = stated
    prop["listings"] = [
        {
            "source": l.get("source"),
            "url": l.get("url"),
            "agent": l.get("agent"),
            "price_jpy": l.get("price_jpy"),
            "title": l.get("title"),
            "has_detail": bool(l.get("has_detail")),
        }
        for l in sorted(group, key=lambda l: (l.get("source") or "", l.get("url") or ""))
    ]
    prop["urls"] = [l["url"] for l in prop["listings"] if l.get("url")]
    prop["sources"] = sorted({l["source"] for l in prop["listings"] if l.get("source")})
    prop["id"] = property_id(prop)
    return prop
