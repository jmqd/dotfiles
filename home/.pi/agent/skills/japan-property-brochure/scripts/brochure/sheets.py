"""Contact sheets: every downloaded photo on a few labelled pages, for looking through them quickly."""

from __future__ import annotations

import html
from pathlib import Path
from typing import List

import chrome
from store import BrochureError, Folder

PER_SHEET = 12
WIDTH, HEIGHT = 1600, 1140

_CSS = """
body { margin: 0; padding: 14px; width: 1600px; height: 1140px; box-sizing: border-box; background: #fff;
       font: 15px -apple-system, "Helvetica Neue", "Hiragino Sans", "Noto Sans CJK JP", sans-serif; }
.grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
.cell { border: 1px solid #ccd2cf; }
.cell .img { height: 330px; background: #eef1ef; }
.cell img { width: 100%; height: 100%; object-fit: contain; display: block; }
.cell p { margin: 0; padding: 5px 8px 6px; line-height: 1.3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.cell b { font-size: 19px; margin-right: 8px; }
"""


def build(folder: Folder) -> List[Path]:
    """Write sheets/sheet-NN.png, twelve photos each, labelled with id, category and pixel size."""
    data = folder.require(folder.photos, "run `brochure photos` first")
    photos = [p for p in data["photos"] if p.get("status") == "ok"]
    if not photos:
        raise BrochureError("photos.json holds no downloaded photos")
    folder.sheets_dir.mkdir(parents=True, exist_ok=True)
    made = []
    for start in range(0, len(photos), PER_SHEET):
        number = start // PER_SHEET + 1
        cells = []
        for photo in photos[start : start + PER_SHEET]:
            cells.append(
                '<div class="cell"><div class="img"><img src="../%s"></div><p><b>%s</b>%s · %d×%d</p></div>'
                % (html.escape(photo["file"]), html.escape(photo["id"]), html.escape(photo.get("category") or "(no category)"),
                   photo["width"], photo["height"])
            )
        page = folder.sheets_dir / ("sheet-%02d.html" % number)
        page.write_text(
            '<!doctype html><html lang="ja"><head><meta charset="utf-8"><style>%s</style></head><body><div class="grid">%s</div></body></html>'
            % (_CSS, "".join(cells)),
            encoding="utf-8",
        )
        image = folder.sheets_dir / ("sheet-%02d.png" % number)
        chrome.to_png(page, image, WIDTH, HEIGHT)
        made.append(image)
    return made
