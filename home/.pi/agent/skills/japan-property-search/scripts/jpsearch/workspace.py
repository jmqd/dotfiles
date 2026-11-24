"""Where a search keeps its files.

    <home>/profile.json                 the buyer's criteria (edit this)
    <home>/search/state.json            what earlier runs saw: first seen, prices, marks
    <home>/search/cache/discover/       city lists per site, reused between runs
    <home>/search/runs/<date>/          one run: plan, raw captures, report

`home` defaults to $JP_PROPERTY_HOME, else ~/japan-property.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Optional


def default_home() -> Path:
    return Path(os.environ.get("JP_PROPERTY_HOME") or Path.home() / "japan-property")


def today() -> str:
    return datetime.date.today().isoformat()


def slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")[:80] or "x"


def url_key(url: str) -> str:
    return hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]


class Workspace:
    def __init__(self, home: Path, run: str) -> None:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(?:[-_.][A-Za-z0-9]+)?", run):
            raise ValueError("run must look like 2026-11-25 or 2026-11-25-b, got %r" % run)
        self.home = home
        self.run = run
        self.run_date = run[:10]
        self.profile_path = home / "profile.json"
        self.search_dir = home / "search"
        self.state_path = self.search_dir / "state.json"
        self.discover_dir = self.search_dir / "cache" / "discover"
        self.run_dir = self.search_dir / "runs" / run
        self.plan_path = self.run_dir / "plan.json"
        self.robots_dir = self.run_dir / "robots"
        self.raw_dir = self.run_dir / "raw"

    def robots_path(self, host: str) -> Path:
        return self.robots_dir / (slug(host) + ".json")

    def list_path(self, source: str, key: str, page: int) -> Path:
        return self.raw_dir / "list" / source / ("%s-p%02d.json" % (slug(key), page))

    def detail_path(self, url: str) -> Path:
        return self.raw_dir / "detail" / (url_key(url) + ".json")

    def discover_run_path(self, source: str, key: str) -> Path:
        return self.raw_dir / "discover" / source / (slug(key) + ".json")

    def discover_cache_path(self, source: str, listing_type: str, prefecture_slug: str) -> Path:
        return self.discover_dir / source / ("%s-%s.json" % (slug(listing_type), slug(prefecture_slug)))

    def relative(self, path: Path) -> str:
        return str(path.relative_to(self.home))


def read_json(path: Path) -> Optional[Any]:
    """The file's JSON, or None when the file does not exist.

    A file that exists but does not parse raises: a half-written capture must
    not be mistaken for a missing one and silently refetched or skipped.
    """
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: Any) -> None:
    """Write atomically, so an interrupted run never leaves a truncated file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)
