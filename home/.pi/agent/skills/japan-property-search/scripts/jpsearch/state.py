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
    state: Dict[str, Any],
    run: str,
    run_date: str,
    properties: List[Dict[str, Any]],
    searched_sources: List[str],
    ruled_out: Optional[Dict[str, str]] = None,
) -> List[Dict[str, Any]]:
    """Record this run's candidate properties and return them annotated with history.

    `properties` are the non-rejected properties, each with `status` set.
    `searched_sources` are the sources whose search completed; a tracked
    property is marked gone only when every source that listed it was
    searched and none of them shows it now. `ruled_out` maps the URL of
    each listing this run read and rejected to the reason: a tracked
    property that is still listed but no longer qualifies is recorded as
    dropped with that reason, which is a different thing from gone.

    A run is built more than once (after a retry, after adding notes), so
    what changed is measured against the state before the run first touched
    a property, which each entry keeps in `before`. Building twice gives the
    same answer as building once.
    """
    ruled_out = ruled_out or {}
    tracked = state["properties"]
    url_index = {url: pid for pid, entry in tracked.items() for url in entry["urls"]}
    seen_now = set()
    out = []
    for prop in properties:
        pid = _resolve_id(state, url_index, prop)
        entry = tracked.get(pid)
        if entry is None:
            entry = tracked[pid] = {
                "first_seen": run_date, "last_seen": run_date, "urls": [], "sources": [], "prices": [],
                "statuses": [], "mark": None, "note": "", "gone_since": None, "snapshot": {},
                "before": {"run": run, "known": False, "price": None, "gone": False},
            }
        elif (entry.get("before") or {}).get("run") != run:
            entry["before"] = {
                "run": run,
                "known": True,
                "price": entry["prices"][-1][1] if entry["prices"] else None,
                "gone": bool(entry.get("gone_since")),
            }
        before = entry["before"]
        price = prop.get("price_jpy")
        if not before["known"]:
            change = "new"
        elif before["gone"]:
            change = "relisted"
        elif price is not None and before["price"] is not None and price != before["price"]:
            change = "price_down" if price < before["price"] else "price_up"
        else:
            change = "seen"
        if price is not None and (not entry["prices"] or entry["prices"][-1][1] != price):
            entry["prices"].append([run_date, price])
        if not entry["statuses"] or entry["statuses"][-1][1] != prop["status"]:
            entry["statuses"].append([run_date, prop["status"]])
        entry["last_seen"] = run_date
        entry["gone_since"] = None
        entry["dropped"] = None
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
                previous_price_jpy=before["price"] if change in ("price_down", "price_up") else None,
                prices=entry["prices"],
                mark=entry.get("mark"),
                note=entry.get("note") or "",
            )
        )
    searched = set(searched_sources)
    for pid, entry in list(tracked.items()):
        if pid in seen_now:
            continue
        before = entry.get("before") or {}
        reason = next((ruled_out[url] for url in entry["urls"] if url in ruled_out), None)
        if before.get("run") == run and not before.get("known"):
            # An earlier build of this same run recorded it, and the finished run no longer holds it
            # (its detail page ruled it out): it was never a candidate, so it is not "gone" either.
            del tracked[pid]
        elif reason is not None:
            # Still listed, and this run's reading rules it out. Reported once, in the run that found it.
            if not entry.get("dropped") or entry["dropped"]["run"] == run:
                entry["dropped"] = {"run": run, "reason": reason}
            entry["gone_since"] = None
        elif not entry.get("gone_since") and entry.get("sources") and set(entry["sources"]) <= searched:
            entry["gone_since"] = run_date
    state["runs"] = [r for r in state["runs"] if r["run"] != run] + [
        {"run": run, "date": run_date, "candidates": len(out), "searched_sources": sorted(searched)}
    ]
    return out


def _history_row(pid: str, entry: Dict[str, Any]) -> Dict[str, Any]:
    return dict(entry["snapshot"], id=pid, urls=entry["urls"], prices=entry["prices"], first_seen=entry["first_seen"])


def gone(state: Dict[str, Any], run_date: str) -> List[Dict[str, Any]]:
    """Tracked properties that this run found delisted."""
    return [_history_row(pid, entry) for pid, entry in sorted(state["properties"].items()) if entry.get("gone_since") == run_date]


def dropped(state: Dict[str, Any], run: str) -> List[Dict[str, Any]]:
    """Tracked properties that are still listed and that this run ruled out, each with the reason."""
    return [
        dict(_history_row(pid, entry), reason=entry["dropped"]["reason"])
        for pid, entry in sorted(state["properties"].items())
        if (entry.get("dropped") or {}).get("run") == run
    ]


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
