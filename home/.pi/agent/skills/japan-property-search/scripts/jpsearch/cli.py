"""Command-line interface for the property search tools."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

import criteria
import dedupe
import pipeline
import plan as planning
import registry
import report
import robots
import state as state_store
from workspace import Workspace, default_home, today, url_key, write_json

SKILL_DIR = Path(__file__).resolve().parent.parent.parent
DEFAULT_PROFILE = SKILL_DIR / "references" / "default-profile.json"
JPX_PATH = SKILL_DIR / "scripts" / "jpx.js"


def _workspace(args: argparse.Namespace) -> Workspace:
    return Workspace(Path(args.home).expanduser() if args.home else default_home(), args.run or today())


def _load(args: argparse.Namespace) -> Tuple[Workspace, criteria.Profile, List[registry.Source], Dict[str, Any]]:
    ws = _workspace(args)
    if not ws.profile_path.exists():
        raise SystemExit("no profile at %s; run `jpsearch init` first" % ws.profile_path)
    return ws, criteria.load_profile(ws.profile_path), registry.load_registry(), state_store.load(ws)


def _cmd_init(args: argparse.Namespace) -> int:
    ws = _workspace(args)
    ws.home.mkdir(parents=True, exist_ok=True)
    if ws.profile_path.exists():
        print("profile already exists: %s" % ws.profile_path)
    else:
        shutil.copyfile(DEFAULT_PROFILE, ws.profile_path)
        print("wrote %s; edit it to change the criteria" % ws.profile_path)
    criteria.load_profile(ws.profile_path)
    return 0


def _cmd_plan(args: argparse.Namespace) -> int:
    ws, profile, sources, state = _load(args)
    document = planning.Planner(ws, profile, sources, state).build()
    document["jpx"] = str(JPX_PATH)
    write_json(ws.plan_path, document)
    counts = document["counts"]
    todo = [t for t in document["tasks"] if t["status"] == planning.TODO]
    by_host: Dict[str, int] = {}
    for task in todo:
        by_host[task["host"]] = by_host.get(task["host"], 0) + 1
    print("plan: %s" % ws.plan_path)
    print("tasks: " + ", ".join("%s %d" % (k, counts[k]) for k in sorted(counts)))
    for host, n in sorted(by_host.items()):
        print("  todo %-34s %d" % (host, n))
    if not todo:
        waiting = counts.get(planning.WAITING, 0)
        print("nothing left to fetch" + ("; %d tasks wait on robots.txt that could not be planned" % waiting if waiting else ""))
    return 0


def _rejection(verdict: criteria.Verdict) -> str:
    return "; ".join(verdict.reasons(criteria.FAIL))


def _cmd_build(args: argparse.Namespace) -> int:
    ws, profile, sources, state = _load(args)
    planner = planning.Planner(ws, profile, sources, state)
    document = planner.build()
    document["jpx"] = str(JPX_PATH)
    write_json(ws.plan_path, document)
    coverage = planning.coverage(document, sources, profile)

    records, captures = pipeline.usable_details(ws, state, profile.detail_cache_days)
    state_store.remember_details(state, ws.run_date, records)
    merged = pipeline.merged_listings(planner.cards, records, captures)

    rejected: List[Dict[str, Any]] = []
    live: List[Dict[str, Any]] = []
    for listing in merged:
        verdict = criteria.judge(profile, listing)
        if verdict.status == criteria.REJECTED:
            rejected.append(dict(listing, reason=_rejection(verdict)))
        else:
            live.append(listing)

    candidates: List[Dict[str, Any]] = []
    for group in dedupe.cluster(live):
        prop = dedupe.merge(group)
        verdict = criteria.judge(profile, prop)
        if verdict.status == criteria.REJECTED:
            rejected.extend(dict(listing, reason=_rejection(verdict)) for listing in group)
            continue
        prop["status"] = verdict.status
        prop["zone"] = verdict.zone
        prop["open_points"] = verdict.reasons(criteria.UNKNOWN, criteria.NEAR)
        prop["checks"] = [{"criterion": c.criterion, "result": c.result, "detail": c.detail} for c in verdict.checks]
        candidates.append(prop)

    searched = [row["id"] for row in coverage if row["outcome"] == "searched"]
    annotated = state_store.apply_run(state, ws.run, ws.run_date, candidates, searched)
    gone = state_store.gone(state, ws.run_date)
    state_store.save(ws, state)
    paths = report.write_all(ws, profile, annotated, rejected, gone, coverage, len(merged))

    by_status: Dict[str, int] = {}
    for prop in annotated:
        by_status[prop["status"]] = by_status.get(prop["status"], 0) + 1
    print("listings read: %d; rejected: %d" % (len(merged), len(rejected)))
    print("properties: " + (", ".join("%s %d" % (k, by_status[k]) for k in sorted(by_status)) or "none"))
    print("new this run: %d; delisted: %d" % (sum(1 for p in annotated if p["change"] == "new"), len(gone)))
    unfinished = document["counts"].get(planning.TODO, 0) + document["counts"].get(planning.WAITING, 0)
    if unfinished:
        print("WARNING: %d tasks were still unfetched; this report is incomplete" % unfinished)
    for row in coverage:
        if row["outcome"] in ("failed", "partial", "incomplete"):
            print("source %s: %s (%s)" % (row["id"], row["outcome"], "; ".join(row["problems"])[:200]))
    for name in ("html", "markdown", "csv", "json", "rejected"):
        print("%-9s %s" % (name, paths[name]))
    return 0


def _cmd_mark(args: argparse.Namespace) -> int:
    ws = _workspace(args)
    state = state_store.load(ws)
    try:
        pid, entry = state_store.set_mark(state, args.id, args.mark, args.note)
    except KeyError as exc:
        print(exc.args[0], file=sys.stderr)
        return 1
    state_store.save(ws, state)
    print("%s: mark=%s note=%r" % (pid, entry.get("mark"), entry.get("note")))
    return 0


def _cmd_add(args: argparse.Namespace) -> int:
    """File a page captured by hand so the next `build` includes it."""
    ws = _workspace(args)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,40}", args.source):
        print("error: --source must be a short lower-case id such as athome or karuizawa-sato", file=sys.stderr)
        return 2
    try:
        result = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print("error: cannot read %s: %s" % (args.file, exc), file=sys.stderr)
        return 2
    if args.kind == "list":
        url = args.url or (result.get("info") or {}).get("url")
        if not isinstance(result.get("cards"), list) or not url:
            print("error: a list capture needs 'cards' and 'info.url' (the output of JPX.cards and JPX.pageInfo)", file=sys.stderr)
            return 2
        out = ws.raw_dir / "list" / args.source / ("hand-%s.json" % url_key(url))
    else:
        url = args.url or result.get("url")
        if not isinstance(result.get("pairs"), list) or not url:
            print("error: a detail capture needs 'pairs' and 'url' (the output of JPX.detail)", file=sys.stderr)
            return 2
        out = ws.detail_path(url)
    task = {
        "id": "hand:" + out.stem,
        "kind": args.kind,
        "source": args.source,
        "listing_type": args.listing_type,
        "url": url,
        "by_hand": True,
    }
    write_json(out, {"task": task, "fetched_at": datetime.datetime.now().astimezone().isoformat(), "error": None, "result": result})
    count = len(result.get("cards") or []) if args.kind == "list" else len(result.get("pairs") or [])
    print("filed %s (%d %s) as %s" % (url, count, "cards" if args.kind == "list" else "fields", out))
    return 0


def _cmd_sources(_args: argparse.Namespace) -> int:
    for source in registry.load_registry():
        mode = "auto" if source.searches else "manual"
        print("%-18s %-10s %-6s %-8s %s  %s" % (source.id, source.kind, mode, source.access, source.verified, source.home))
    return 0


def _cmd_robots(args: argparse.Namespace) -> int:
    rules = None if args.robots == "none" else Path(args.robots).read_text(encoding="utf-8", errors="replace")
    denied = 0
    for url in args.urls:
        ok = robots.allowed(rules, url)
        denied += 0 if ok else 1
        print(("allow    " if ok else "DISALLOW ") + url)
    return 1 if denied else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jpsearch", description="Search Japanese property listings against a criteria profile.")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--home", help="workspace directory (default: $JP_PROPERTY_HOME or ~/japan-property)")
    common.add_argument("--run", help="run name, a date such as 2026-11-25 (default: today)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init", parents=[common], help="create the workspace and its criteria profile")
    p.set_defaults(func=_cmd_init)

    p = sub.add_parser("plan", parents=[common], help="write plan.json: what to fetch next, given what is already captured")
    p.set_defaults(func=_cmd_plan)

    p = sub.add_parser("build", parents=[common], help="judge, deduplicate and report everything captured in this run")
    p.set_defaults(func=_cmd_build)

    p = sub.add_parser("mark", parents=[common], help="shortlist or dismiss a property, or attach a note to it")
    p.add_argument("id", help="property id from the report (a unique prefix is enough)")
    p.add_argument("mark", nargs="?", choices=list(state_store.MARKS) + ["clear"], help="omit to change only the note")
    p.add_argument("--note", help="free text shown on the property's card")
    p.set_defaults(func=_cmd_mark)

    p = sub.add_parser("add", parents=[common], help="file a page captured by hand (JPX output saved as JSON)")
    p.add_argument("kind", choices=["list", "detail"], help="list: a results page; detail: one property page")
    p.add_argument("file", help="JSON file: {info, cards} for list, JPX.detail() output for detail")
    p.add_argument("--source", required=True, help="source id from `jpsearch sources`, or a new short id for an unlisted site")
    p.add_argument("--listing-type", default="used_house", help="used_house (default), new_house, land or villa")
    p.add_argument("--url", help="page URL, when the capture does not carry it")
    p.set_defaults(func=_cmd_add)

    p = sub.add_parser("sources", help="list the source registry")
    p.set_defaults(func=_cmd_sources)

    p = sub.add_parser("robots", help="check URLs against a saved robots.txt; exit 1 if any is disallowed")
    p.add_argument("robots", help="path to the saved robots.txt, or 'none' when the site has none (404)")
    p.add_argument("urls", nargs="+")
    p.set_defaults(func=_cmd_robots)
    return parser


def main(argv: List[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (criteria.ProfileError, registry.RegistryError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
