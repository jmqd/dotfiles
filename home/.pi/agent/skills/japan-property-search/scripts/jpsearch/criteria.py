"""The buyer's criteria profile and how a property is judged against it.

Every criterion yields one of four results. `unknown` is a first-class
result: a listing that does not state its structure is neither a match nor a
rejection until its detail page has been read.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import text

PASS, NEAR, FAIL, UNKNOWN = "pass", "near", "fail", "unknown"

MATCH, NEAR_MISS, UNVERIFIED, REJECTED = "match", "near", "unverified", "rejected"

STRUCTURE_NAMES = {
    text.RC: "reinforced concrete",
    text.SRC: "steel-reinforced concrete",
    text.STEEL: "steel frame",
    text.WOOD: "wood",
    text.BLOCK: "concrete block",
    text.OTHER: "other",
}

# Every flag a listing can carry, with the wording the report shows. A
# profile may send any of them to review or rejection by name.
FLAGS = {
    "leasehold": "Leasehold land",
    "no_rebuild": "Cannot be rebuilt",
    "urbanisation_control": "Urbanisation control area",
    "setback": "Setback required",
    "notice": "Disclosure item (告知事項)",
    "tenant_occupied": "Tenant in place",
    "not_a_dwelling": "May not be a dwelling",
    "under_negotiation": "Under negotiation",
    "unregistered_part": "Part unregistered",
    "slope_or_retaining_wall": "Slope or retaining wall",
    "hazard_zone": "Hazard zone mentioned",
    "farmland": "Farmland involved",
    "natural_park": "Natural park zone",
    "non_conforming": "Non-conforming building",
    "pre_1981_seismic_code": "Pre-1981 seismic code",
}

# What the buyer has to confirm when a flag sends a property to review.
_REVIEW_ADVICE = {
    "tenant_occupied": "a tenant is in place: confirm it can be bought vacant",
    "not_a_dwelling": "the listing describes a non-residential building: confirm it can be lived in",
}


class ProfileError(ValueError):
    """The profile file is missing a field or holds a value of the wrong kind."""


@dataclass(frozen=True)
class Zone:
    """An area with its own minimum lot size. The first zone that matches an address applies."""

    id: str
    label: str
    land_m2_min: float
    prefecture: Optional[str] = None
    municipality_suffix: Optional[str] = None
    municipalities: tuple = ()

    def covers_prefecture(self, prefecture: str) -> bool:
        return self.prefecture is None or self.prefecture == prefecture

    def matches(self, prefecture: Optional[str], municipality: Optional[str]) -> Optional[bool]:
        """True or False when the address decides it; None when the address is too vague."""
        if self.prefecture is None and not self.municipality_suffix and not self.municipalities:
            return True
        if prefecture is None:
            return None
        if self.prefecture is not None and prefecture != self.prefecture:
            return False
        if not self.municipality_suffix and not self.municipalities:
            return True
        if municipality is None:
            return None
        key = text.municipality_key(municipality)
        if self.municipalities:
            return any(key.startswith(text.municipality_key(m)) for m in self.municipalities)
        return key.endswith(self.municipality_suffix or "")


@dataclass(frozen=True)
class Profile:
    name: str
    listing_types: tuple
    building_m2_min: float
    structures: tuple
    mixed_structure: str
    near_miss_percent: float
    zones: tuple
    price_jpy_max: Optional[int]
    built_year_min: Optional[int]
    review_flags: tuple
    reject_flags: tuple
    areas: tuple
    sources: tuple
    exclude_sources: tuple
    request_delay_seconds: float
    detail_cache_days: int
    max_detail_pages: int

    @property
    def near_factor(self) -> float:
        return 1.0 - self.near_miss_percent / 100.0

    def zone_for(self, prefecture: Optional[str], municipality: Optional[str]) -> Optional[Zone]:
        """The zone an address falls in, or None when the address cannot decide between zones."""
        for zone in self.zones:
            verdict = zone.matches(prefecture, municipality)
            if verdict is None:
                return None
            if verdict:
                return zone
        return None

    def land_floor(self, prefecture: str, municipality: Optional[str] = None) -> float:
        """Smallest lot worth fetching for an area, near misses included.

        With only a prefecture known, this is the loosest zone that can occur
        there, so a prefecture-wide query never hides a qualifying house.
        """
        zone = self.zone_for(prefecture, municipality) if municipality else None
        if zone is not None:
            return zone.land_m2_min * self.near_factor
        candidates = [z.land_m2_min for z in self.zones if z.covers_prefecture(prefecture)]
        return min(candidates) * self.near_factor

    @property
    def building_floor(self) -> float:
        return self.building_m2_min * self.near_factor


def _require(data: Dict[str, Any], key: str, kinds: tuple) -> Any:
    if key not in data:
        raise ProfileError("profile is missing '%s'" % key)
    value = data[key]
    if not isinstance(value, kinds) or isinstance(value, bool) and bool not in kinds:
        raise ProfileError("profile field '%s' has the wrong type: %r" % (key, value))
    return value


def _flag_list(data: Dict[str, Any], key: str, default: tuple) -> tuple:
    value = data.get(key, list(default))
    if not isinstance(value, list) or any(f not in FLAGS for f in value):
        raise ProfileError("'%s' must be a list of flags from: %s" % (key, ", ".join(FLAGS)))
    return tuple(value)


def _areas(value: Any) -> tuple:
    if value in (None, "all"):
        return text.PREFECTURES
    if not isinstance(value, list) or not value:
        raise ProfileError("'areas' must be \"all\" or a list of prefectures")
    out = []
    for item in value:
        address = text.parse_address(str(item))
        if address.prefecture is None:
            raise ProfileError("'areas' entry is not a prefecture: %r" % (item,))
        out.append(address.prefecture)
    return tuple(dict.fromkeys(out))


def parse_profile(data: Dict[str, Any]) -> Profile:
    """Turn the JSON document into a Profile, rejecting anything malformed."""
    zones = []
    for raw in _require(data, "zones", (list,)):
        zones.append(
            Zone(
                id=str(_require(raw, "id", (str,))),
                label=str(raw.get("label") or raw["id"]),
                land_m2_min=float(_require(raw, "land_m2_min", (int, float))),
                prefecture=raw.get("prefecture"),
                municipality_suffix=raw.get("municipality_suffix"),
                municipalities=tuple(raw.get("municipalities") or ()),
            )
        )
    if not zones:
        raise ProfileError("profile needs at least one zone")
    last = zones[-1]
    if last.prefecture or last.municipality_suffix or last.municipalities:
        raise ProfileError("the last zone must be the catch-all (no prefecture or municipality)")
    mixed = data.get("mixed_structure", "review")
    if mixed not in ("review", "accept", "reject"):
        raise ProfileError("'mixed_structure' must be review, accept or reject")
    structures = tuple(_require(data, "structures", (list,)))
    unknown = [s for s in structures if s not in STRUCTURE_NAMES]
    if unknown:
        raise ProfileError("unknown structure codes %r; use %s" % (unknown, ", ".join(STRUCTURE_NAMES)))
    near = float(data.get("near_miss_percent", 10))
    if not 0 <= near < 50:
        raise ProfileError("'near_miss_percent' must be between 0 and 50")
    delay = float(data.get("request_delay_seconds", 3))
    if delay < 2:
        raise ProfileError("'request_delay_seconds' must be at least 2")
    return Profile(
        name=str(data.get("name") or "profile"),
        listing_types=tuple(data.get("listing_types") or ("used_house",)),
        building_m2_min=float(_require(data, "building_m2_min", (int, float))),
        structures=structures,
        mixed_structure=mixed,
        near_miss_percent=near,
        zones=tuple(zones),
        price_jpy_max=data.get("price_jpy_max"),
        built_year_min=data.get("built_year_min"),
        review_flags=_flag_list(data, "review_flags", ("tenant_occupied", "not_a_dwelling")),
        reject_flags=_flag_list(data, "reject_flags", ()),
        areas=_areas(data.get("areas")),
        sources=tuple(data.get("sources") or ()) if data.get("sources") not in (None, "all") else (),
        exclude_sources=tuple(data.get("exclude_sources") or ()),
        request_delay_seconds=delay,
        detail_cache_days=int(data.get("detail_cache_days", 30)),
        max_detail_pages=int(data.get("max_detail_pages", 400)),
    )


def load_profile(path: Path) -> Profile:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ProfileError("%s is not valid JSON: %s" % (path, exc)) from exc
    return parse_profile(data)


# ---------------------------------------------------------------- judging


@dataclass
class Check:
    criterion: str
    result: str
    detail: str


@dataclass
class Verdict:
    status: str
    zone: Optional[str]
    checks: List[Check] = field(default_factory=list)

    def reasons(self, *results: str) -> List[str]:
        return [c.detail for c in self.checks if c.result in results]


def _minimum(criterion: str, value: Optional[float], minimum: float, near_factor: float, unit: str) -> Check:
    if value is None:
        return Check(criterion, UNKNOWN, "%s not stated" % criterion)
    if value >= minimum:
        return Check(criterion, PASS, "%s %.2f %s >= %g" % (criterion, value, unit, minimum))
    if value >= minimum * near_factor:
        return Check(criterion, NEAR, "%s %.2f %s is just under %g" % (criterion, value, unit, minimum))
    return Check(criterion, FAIL, "%s %.2f %s < %g" % (criterion, value, unit, minimum))


def _one_structure(profile: Profile, kind: Optional[str], parts: List[str], hinted: bool) -> Check:
    if kind is None:
        hint = "; the listing text mentions concrete" if hinted else ""
        return Check("structure", UNKNOWN, "structure not stated" + hint)
    if kind == text.OTHER:
        return Check("structure", UNKNOWN, "structure stated only as 'other'")
    if kind == text.MIXED:
        wanted = [p for p in parts if p in profile.structures]
        names = " + ".join(STRUCTURE_NAMES.get(p, p) for p in parts)
        if len(wanted) == len(parts):
            return Check("structure", PASS, "structure is %s" % names)
        if not wanted or profile.mixed_structure == "reject":
            return Check("structure", FAIL, "mixed structure (%s)" % names)
        if profile.mixed_structure == "accept":
            return Check("structure", PASS, "mixed structure (%s)" % names)
        return Check("structure", NEAR, "mixed structure (%s): confirm which part is concrete" % names)
    name = STRUCTURE_NAMES.get(kind, kind)
    if kind in profile.structures:
        return Check("structure", PASS, "structure is %s" % name)
    return Check("structure", FAIL, "structure is %s" % name)


def _structure(profile: Profile, prop: Dict[str, Any]) -> Check:
    """The structure check, over every structure the property's listings state.

    Agents listing one house sometimes state different structures. When
    they do, the property passes or fails only if every statement agrees on
    that; otherwise it goes to review with the statements side by side.
    """
    hinted = bool(prop.get("concrete_hint"))
    variants = prop.get("structure_variants") or []
    if len(variants) < 2:
        return _one_structure(profile, prop.get("structure"), list(prop.get("structure_parts") or []), hinted)
    checks = [_one_structure(profile, v["kind"], list(v["parts"]), hinted) for v in variants]
    results = {c.result for c in checks}
    stated = " / ".join(v["text"] for v in variants)
    if results == {PASS}:
        return Check("structure", PASS, "structure is acceptable in every listing (%s)" % stated)
    if results == {FAIL}:
        return Check("structure", FAIL, "no listing states an accepted structure (%s)" % stated)
    return Check("structure", NEAR, "listings disagree on the structure (%s): confirm it" % stated)


def judge(profile: Profile, prop: Dict[str, Any]) -> Verdict:
    """Judge one property record (see listings.normalise for its fields)."""
    checks: List[Check] = []
    zone = profile.zone_for(prop.get("prefecture"), prop.get("municipality"))

    if prop.get("listing_type") not in profile.listing_types:
        checks.append(Check("type", FAIL, "listing type %s is not searched" % prop.get("listing_type")))

    # A site searched nationwide returns houses everywhere; the profile's areas still bound the result.
    prefecture = prop.get("prefecture")
    if prefecture is not None and prefecture not in profile.areas:
        checks.append(Check("area", FAIL, "%s is outside the profile's areas" % prefecture))
    elif prefecture is None and len(profile.areas) < len(text.PREFECTURES):
        checks.append(Check("area", UNKNOWN, "the listing does not say which prefecture it is in"))

    checks.append(_minimum("building area", prop.get("building_m2"), profile.building_m2_min, profile.near_factor, "m2"))

    if zone is None:
        loosest = min(z.land_m2_min for z in profile.zones)
        land = prop.get("land_m2")
        if land is not None and land < loosest * profile.near_factor:
            checks.append(Check("land area", FAIL, "land area %.2f m2 is below every zone's minimum" % land))
        else:
            checks.append(Check("land area", UNKNOWN, "address too vague to choose a zone: %s" % (prop.get("address") or "none")))
    else:
        checks.append(_minimum("land area", prop.get("land_m2"), zone.land_m2_min, profile.near_factor, "m2"))

    checks.append(_structure(profile, prop))

    if profile.price_jpy_max is not None:
        price = prop.get("price_jpy")
        if price is None:
            checks.append(Check("price", UNKNOWN, "price not disclosed"))
        elif price > profile.price_jpy_max:
            checks.append(Check("price", FAIL, "price %d > %d" % (price, profile.price_jpy_max)))
        else:
            checks.append(Check("price", PASS, "price within limit"))

    if profile.built_year_min is not None:
        year = prop.get("built_year")
        if year is None:
            checks.append(Check("built", UNKNOWN, "year built not stated"))
        elif year < profile.built_year_min:
            checks.append(Check("built", FAIL, "built %d, before %d" % (year, profile.built_year_min)))
        else:
            checks.append(Check("built", PASS, "built %d" % year))

    flags = prop.get("flags") or []
    for flag in profile.reject_flags:
        if flag in flags:
            checks.append(Check(flag, FAIL, "%s, which the profile rejects" % FLAGS[flag].lower()))
    for flag in profile.review_flags:
        if flag in flags and flag not in profile.reject_flags:
            checks.append(Check(flag, NEAR, _REVIEW_ADVICE.get(flag, "%s: review before treating it as a match" % FLAGS[flag].lower())))

    results = {c.result for c in checks}
    if FAIL in results:
        status = REJECTED
    elif UNKNOWN in results:
        status = UNVERIFIED
    elif NEAR in results:
        status = NEAR_MISS
    else:
        status = MATCH
    return Verdict(status, zone.id if zone else None, checks)
