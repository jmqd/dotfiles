"""What earlier runs saw, so each run can say what is new, repriced or gone.

state.json is the authority for a property's identity over time, its price
history, cached detail pages and the buyer's own marks. A run reads it,
applies its results and replaces the file atomically.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

from workspace import Workspace, read_json, write_json

VERSION = 1
MARKS = ("shortlist", "dismissed")

_SNAPSHOT_FIELDS = (
    "title", "address", "prefecture", "municipality", "land_m2", "building_m2", "built_year", "structure",
    "layout", "image", "listing_type",
)


def load(ws: Workspace) -> Dict[str, Any]:
    state = read_json(ws.state_path)
    if state is None:
        return {"version": VERSION, "properties": {}, "details": {}, "runs": []}
    if state.get("version") != VERSION:
        raise ValueError("%s has version %r; this tool reads version %d" % (ws.state_path, state.get("version"), VERSION))
    return state


def save(ws: Workspace, state: Dict[str, Any]) -> None:
    write_json(ws.state_path, state)


def remember_details(state: Dict[str, Any], run_date: str, records: Dict[str, Dict[str, Any]]) -> None:
    """Cache this run's detail records so later runs need not refetch unchanged listings."""
    for url, record in records.items():
        if record.get("seen") == run_date:
            state["details"][url] = {"captured": run_date, "record": record}


def _resolve_id(state: Dict[str, Any], url_index: Dict[str, str], prop: Dict[str, Any]) -> str:
    """The id this property already has, found through any URL it was seen at before."""
    known = sorted(
        {url_index[u] for u in prop["urls"] if u in url_index},
        key=lambda pid: (state["properties"][pid]["first_seen"], pid),
    )
    if not known:
        return prop["id"]
    keep = known[0]
    for other in known[1:]:
        # Two tracked records turned out to be one property: fold the later into the earlier.
        merged = state["properties"].pop(other)
        entry = state["properties"][keep]
        entry["urls"] = sorted(set(entry["urls"]) | set(merged["urls"]))
        entry["prices"] = sorted(entry["prices"] + merged["prices"])
        entry["mark"] = entry.get("mark") or merged.get("mark")
        entry["note"] = entry.get("note") or merged.get("note")
        for url in merged["urls"]:
            url_index[url] = keep
    return keep


def apply_run(
    state: Dict[str, Any], run: str, run_date: str, properties: List[Dict[str, Any]], searched_sources: List[str]
) -> List[Dict[str, Any]]:
    """Record this run's candidate properties and return them annotated with history.

    `properties` are the non-rejected properties, each with `status` set.
    `searched_sources` are the sources whose search completed; a tracked
    property is marked gone only when every source that listed it was
    searched and none of them shows it now.
    """
    tracked = state["properties"]
    url_index = {url: pid for pid, entry in tracked.items() for url in entry["urls"]}
    seen_now = set()
    out = []
    for prop in properties:
        pid = _resolve_id(state, url_index, prop)
        entry = tracked.get(pid)
        change = "seen"
        if entry is None:
            entry = tracked[pid] = {
                "first_seen": run_date, "last_seen": run_date, "urls": [], "sources": [], "prices": [],
                "statuses": [], "mark": None, "note": "", "gone_since": None, "snapshot": {},
            }
            change = "new"
        elif entry.get("gone_since"):
            change = "relisted"
        price = prop.get("price_jpy")
        last_price = entry["prices"][-1][1] if entry["prices"] else None
        if price is not None and price != last_price:
            entry["prices"].append([run_date, price])
            if last_price is not None and change == "seen":
                change = "price_down" if price < last_price else "price_up"
        if not entry["statuses"] or entry["statuses"][-1][1] != prop["status"]:
            entry["statuses"].append([run_date, prop["status"]])
        entry["last_seen"] = run_date
        entry["gone_since"] = None
        entry["urls"] = sorted(set(entry["urls"]) | set(prop["urls"]))
        entry["sources"] = sorted(set(entry.get("sources") or []) | set(prop["sources"]))
        entry["snapshot"] = {f: prop.get(f) for f in _SNAPSHOT_FIELDS}
        for url in prop["urls"]:
            url_index[url] = pid
        seen_now.add(pid)
        out.append(
            dict(
                prop,
                id=pid,
                change=change,
                first_seen=entry["first_seen"],
                previous_price_jpy=last_price if change in ("price_down", "price_up") else None,
                prices=entry["prices"],
                mark=entry.get("mark"),
                note=entry.get("note") or "",
            )
        )
    searched = set(searched_sources)
    for pid, entry in tracked.items():
        if pid in seen_now or entry.get("gone_since"):
            continue
        if entry.get("sources") and set(entry["sources"]) <= searched:
            entry["gone_since"] = run_date
    state["runs"] = [r for r in state["runs"] if r["run"] != run] + [
        {"run": run, "date": run_date, "candidates": len(out), "searched_sources": sorted(searched)}
    ]
    return out


def gone(state: Dict[str, Any], run_date: str) -> List[Dict[str, Any]]:
    """Tracked properties that this run found delisted."""
    rows = []
    for pid, entry in sorted(state["properties"].items()):
        if entry.get("gone_since") == run_date:
            rows.append(dict(entry["snapshot"], id=pid, urls=entry["urls"], prices=entry["prices"], first_seen=entry["first_seen"]))
    return rows


def set_mark(state: Dict[str, Any], property_id: str, mark: Optional[str], note: Optional[str]) -> Tuple[str, Dict[str, Any]]:
    """Set the buyer's mark or note on a tracked property. Accepts a unique id prefix."""
    matches = [pid for pid in state["properties"] if pid.startswith(property_id)]
    if len(matches) != 1:
        raise KeyError("%r matches %d tracked properties; give a unique id" % (property_id, len(matches)))
    entry = state["properties"][matches[0]]
    if mark is not None:
        entry["mark"] = None if mark == "clear" else mark
    if note is not None:
        entry["note"] = note
    return matches[0], entry
