"""Download every photo of the listing at the largest size the site stores."""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

import imagesize
from net import Disallowed, FetchFailed, Fetcher
from store import BrochureError, Folder, read_json, write_json

# How many guessed URL forms to try for one photo before the URL as captured.
MAX_GUESSES = 2


def _load(folder: Folder) -> Dict[str, Dict[str, Any]]:
    data = read_json(folder.photos) or {"photos": []}
    return {p["id"]: p for p in data["photos"]}


def _save(folder: Folder, records: Dict[str, Dict[str, Any]], order: List[str]) -> None:
    extra = sorted(pid for pid in records if pid not in order)
    write_json(folder.photos, {"photos": [records[pid] for pid in order + extra if pid in records]})


def _fetch(fetcher: Fetcher, url: str, referer: str) -> Dict[str, Any]:
    """One URL as an image with its size and hash, or why it is not one."""
    try:
        _kind, body = fetcher.get(url, referer=referer)
    except Disallowed as error:
        return {"ok": False, "error": str(error), "disallowed": True}
    except FetchFailed as error:
        return {"ok": False, "error": str(error), "disallowed": False}
    size = imagesize.dimensions(body)
    if size is None:
        return {"ok": False, "error": "%s did not return an image" % url, "disallowed": False}
    return {"ok": True, "url": url, "body": body, "width": size[0], "height": size[1], "ext": size[2],
            "sha256": hashlib.sha256(body).hexdigest()}


def _fetch_best(
    fetcher: Fetcher, photo: Dict[str, Any], referer: str, saved: Dict[str, str], placeholders: Set[str]
) -> Dict[str, Any]:
    """The first URL form that returns this photo, or the reasons none did.

    The forms before the URL as captured are guesses at a larger version.
    A guess is refused when it returns fewer pixels than the page showed, or
    the very bytes saved for another photo: both are what a site sends in
    place of a picture it does not have. `saved` maps content hash to the
    photo saved with it; a hash found to stand in for a second photo is
    added to `placeholders`.
    """
    errors: List[str] = []
    blocked = False
    guesses = [u for u in photo["candidates"] if u != photo["url"]][:MAX_GUESSES]
    for url in guesses + [photo["url"]]:
        got = _fetch(fetcher, url, referer)
        if not got["ok"]:
            blocked = blocked or got["disallowed"]
            errors.append(got["error"])
            continue
        if url != photo["url"]:
            if got["width"] * got["height"] < (photo.get("page_pixels") or 0):
                errors.append("%s is smaller than the image on the page" % url)
                continue
            if got["sha256"] in placeholders or saved.get(got["sha256"], photo["id"]) != photo["id"]:
                placeholders.add(got["sha256"])
                errors.append("%s returned a file already served for another photo: a placeholder" % url)
                continue
        return got
    return {"ok": False, "errors": errors, "disallowed": blocked}


def download(folder: Folder, fetcher: Optional[Fetcher] = None) -> Dict[str, int]:
    """Fetch the photos listing.json names that are not on disk yet. Safe to run again."""
    listing = folder.require(folder.listing, "run `brochure ingest` first")
    fetcher = fetcher or Fetcher()
    order = [p["id"] for p in listing["photos"]]
    # A record of a photo the listing no longer has (a later ingest set it aside) would be reported
    # as a failure nobody can fix. Photos added by hand are not the listing's to drop.
    records = {pid: r for pid, r in _load(folder).items() if pid in order or r.get("added_from")}
    by_hash = {r["sha256"]: pid for pid, r in records.items() if r.get("status") == "ok"}
    placeholders: Set[str] = set()
    folder.photos_dir.mkdir(parents=True, exist_ok=True)
    counts = {"ok": 0, "kept": 0, "duplicate": 0, "failed": 0}

    def store(base: Dict[str, Any], got: Dict[str, Any]) -> None:
        name = "%s.%s" % (base["id"], got["ext"])
        (folder.photos_dir / name).write_bytes(got["body"])
        by_hash[got["sha256"]] = base["id"]
        records[base["id"]] = dict(base, status="ok", file="photos/" + name, url=got["url"], width=got["width"],
                                   height=got["height"], bytes=len(got["body"]), sha256=got["sha256"])

    try:
        for photo in listing["photos"]:
            pid = photo["id"]
            known = records.get(pid)
            if known and known.get("status") in ("ok", "duplicate") and (known["status"] == "duplicate" or (folder.path / known["file"]).exists()):
                counts["kept"] += 1
                continue
            base = {"id": pid, "category": photo.get("category") or "", "caption": photo.get("caption") or "",
                    "section": photo.get("section") or "", "page": photo.get("page"), "source_url": photo["url"]}
            got = _fetch_best(fetcher, photo, listing["url"], by_hash, placeholders)
            if not got["ok"]:
                records[pid] = dict(base, status="failed", disallowed=got["disallowed"], errors=got["errors"])
                counts["failed"] += 1
            elif by_hash.get(got["sha256"], pid) != pid:
                records[pid] = dict(base, status="duplicate", duplicate_of=by_hash[got["sha256"]], sha256=got["sha256"])
                counts["duplicate"] += 1
            else:
                store(base, got)
                counts["ok"] += 1

        # A placeholder is recognised only on its second appearance. The photo that
        # took it first holds no picture of the property: fetch that one as the page had it.
        for pid, record in sorted(records.items()):
            if record.get("status") != "ok" or record.get("sha256") not in placeholders or record["url"] == record["source_url"]:
                continue
            base = {k: record.get(k) for k in ("id", "category", "caption", "section", "page", "source_url")}
            del by_hash[record["sha256"]]
            got = _fetch(fetcher, record["source_url"], listing["url"])
            if got["ok"]:
                store(base, got)
            else:
                records[pid] = dict(base, status="failed", disallowed=got["disallowed"], errors=[got["error"]])
                counts["ok"] -= 1
                counts["failed"] += 1
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
