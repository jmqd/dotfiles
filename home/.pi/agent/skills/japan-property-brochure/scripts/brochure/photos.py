"""Download every photo of the listing at the largest size the site stores."""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional

import imagesize
from net import Disallowed, FetchFailed, Fetcher
from store import BrochureError, Folder, read_json, write_json

# How many URL forms to try for one photo. The capture lists them best first.
MAX_CANDIDATES = 3


def _load(folder: Folder) -> Dict[str, Dict[str, Any]]:
    data = read_json(folder.photos) or {"photos": []}
    return {p["id"]: p for p in data["photos"]}


def _save(folder: Folder, records: Dict[str, Dict[str, Any]], order: List[str]) -> None:
    extra = sorted(pid for pid in records if pid not in order)
    write_json(folder.photos, {"photos": [records[pid] for pid in order + extra if pid in records]})


def _fetch_best(fetcher: Fetcher, photo: Dict[str, Any], referer: str) -> Dict[str, Any]:
    """The first candidate URL that returns an image, with its bytes; or the reasons none did."""
    errors: List[str] = []
    blocked = False
    for url in photo["candidates"][:MAX_CANDIDATES]:
        try:
            _kind, body = fetcher.get(url, referer=referer)
        except Disallowed as error:
            blocked = True
            errors.append(str(error))
            continue
        except FetchFailed as error:
            errors.append(str(error))
            continue
        size = imagesize.dimensions(body)
        if size is None:
            errors.append("%s did not return an image" % url)
            continue
        return {"ok": True, "url": url, "body": body, "width": size[0], "height": size[1], "ext": size[2]}
    return {"ok": False, "errors": errors, "disallowed": blocked}


def download(folder: Folder, fetcher: Optional[Fetcher] = None) -> Dict[str, int]:
    """Fetch the photos listing.json names that are not on disk yet. Safe to run again."""
    listing = folder.require(folder.listing, "run `brochure ingest` first")
    fetcher = fetcher or Fetcher()
    records = _load(folder)
    order = [p["id"] for p in listing["photos"]]
    by_hash = {r["sha256"]: pid for pid, r in records.items() if r.get("status") == "ok"}
    folder.photos_dir.mkdir(parents=True, exist_ok=True)
    counts = {"ok": 0, "kept": 0, "duplicate": 0, "failed": 0}
    try:
        for photo in listing["photos"]:
            pid = photo["id"]
            known = records.get(pid)
            if known and known.get("status") in ("ok", "duplicate") and (known["status"] == "duplicate" or (folder.path / known["file"]).exists()):
                counts["kept"] += 1
                continue
            base = {"id": pid, "category": photo.get("category") or "", "caption": photo.get("caption") or "",
                    "section": photo.get("section") or "", "page": photo.get("page"), "source_url": photo["url"]}
            got = _fetch_best(fetcher, photo, listing["url"])
            if not got["ok"]:
                records[pid] = dict(base, status="failed", disallowed=got["disallowed"], errors=got["errors"])
                counts["failed"] += 1
                continue
            digest = hashlib.sha256(got["body"]).hexdigest()
            if digest in by_hash and by_hash[digest] != pid:
                records[pid] = dict(base, status="duplicate", duplicate_of=by_hash[digest], sha256=digest)
                counts["duplicate"] += 1
                continue
            name = "%s.%s" % (pid, got["ext"])
            (folder.photos_dir / name).write_bytes(got["body"])
            by_hash[digest] = pid
            records[pid] = dict(base, status="ok", file="photos/" + name, url=got["url"], width=got["width"],
                                height=got["height"], bytes=len(got["body"]), sha256=digest)
            counts["ok"] += 1
    finally:
        # Keep what was fetched even when interrupted, so a rerun resumes.
        _save(folder, records, order)
    return counts


def add(folder: Folder, source: Path, photo_id: Optional[str], category: str, caption: str) -> Dict[str, Any]:
    """Register an image obtained another way: saved from the browser, a scan, the buyer's own photo.

    With `photo_id` it fills in a listing photo that could not be downloaded;
    without, it becomes an extra photo with an id of the form x001.
    """
    if not source.exists():
        raise BrochureError("no such file: %s" % source)
    body = source.read_bytes()
    size = imagesize.dimensions(body)
    if size is None:
        raise BrochureError("%s is not a JPEG, PNG, GIF or WebP image" % source)
    records = _load(folder)
    listing = read_json(folder.listing) or {"photos": []}
    order = [p["id"] for p in listing["photos"]]
    if photo_id is None:
        taken = [int(pid[1:]) for pid in records if pid.startswith("x") and pid[1:].isdigit()]
        photo_id = "x%03d" % (max(taken, default=0) + 1)
    elif photo_id not in order and photo_id not in records:
        raise BrochureError("%s is not a photo id of this listing" % photo_id)
    folder.photos_dir.mkdir(parents=True, exist_ok=True)
    name = "%s.%s" % (photo_id, size[2])
    shutil.copyfile(source, folder.photos_dir / name)
    previous = records.get(photo_id, {})
    records[photo_id] = {
        "id": photo_id,
        "category": category or previous.get("category", ""),
        "caption": caption or previous.get("caption", ""),
        "section": previous.get("section", ""),
        "page": previous.get("page"),
        "source_url": previous.get("source_url"),
        "status": "ok",
        "file": "photos/" + name,
        "url": None,
        "added_from": str(source),
        "width": size[0],
        "height": size[1],
        "bytes": len(body),
        "sha256": hashlib.sha256(body).hexdigest(),
    }
    _save(folder, records, order)
    return records[photo_id]
