"""Where one brochure keeps its files.

    <dir>/capture/NN-name.json   JPX.detail() output of the listing page and its sub-pages
    <dir>/listing.json           the captures merged: the Japanese source of truth
    <dir>/photos/pNNN.jpg        every photo of the listing, largest version
    <dir>/photos.json            what was downloaded, with pixel sizes
    <dir>/maps/                  map tiles and maps.json
    <dir>/sheets/                contact sheets for looking through the photos
    <dir>/brochure.json          the English content (written by the agent)
    <dir>/brochure.html, brochure.pdf
    <dir>/pages/page-NNN.jpg     the PDF's pages as images, for review

`<dir>` is normally $JP_PROPERTY_HOME/brochures/<slug> (default ~/japan-property).
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Optional


class BrochureError(Exception):
    """Something the user or the agent has to fix before this step can run."""


def default_home() -> Path:
    return Path(os.environ.get("JP_PROPERTY_HOME") or Path.home() / "japan-property")


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-").lower()[:60]
    if not slug:
        raise BrochureError("the name needs at least one letter or digit: %r" % value)
    return slug


class Folder:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.capture_dir = path / "capture"
        self.listing = path / "listing.json"
        self.photos_dir = path / "photos"
        self.photos = path / "photos.json"
        self.maps_dir = path / "maps"
        self.maps = path / "maps" / "maps.json"
        self.sheets_dir = path / "sheets"
        self.content = path / "brochure.json"
        self.html = path / "brochure.html"
        self.pdf = path / "brochure.pdf"
        self.pages_dir = path / "pages"

    def require(self, path: Path, how: str) -> Any:
        data = read_json(path)
        if data is None:
            raise BrochureError("%s does not exist yet; %s" % (path, how))
        return data


def read_json(path: Path) -> Optional[Any]:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BrochureError("%s is not valid JSON: %s" % (path, exc)) from exc


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, path)
