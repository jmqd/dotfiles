"""Render HTML with a headless Chrome or Chromium: to PDF, to PNG, and PDF pages to images."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import List

from store import BrochureError

_MAC_APPS = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
)
_NAMES = ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome")

_QUIET = (
    "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
    "--disable-extensions", "--disable-component-update", "--disable-background-networking", "--disable-sync",
)


def find() -> str:
    """Path of a Chromium-family browser. $CHROME overrides the search."""
    override = os.environ.get("CHROME")
    if override:
        if not Path(override).exists():
            raise BrochureError("$CHROME points to %s, which does not exist" % override)
        return override
    for path in _MAC_APPS:
        if Path(path).exists():
            return path
    for name in _NAMES:
        found = shutil.which(name)
        if found:
            return found
    raise BrochureError(
        "no Chrome or Chromium found; install one or set $CHROME to its executable. "
        "Without it, print brochure.html to PDF from any browser (A4, background graphics on, no headers)."
    )


def _run(flag: str, extra: List[str], html: Path, out: Path, timeout: float) -> None:
    """Run Chrome until its output file is complete, then stop it and move the file into place.

    Chrome writes the file promptly but can then hang for tens of seconds in
    shutdown, so this waits for the file, not for the process. The previous
    `out` is replaced only by a finished file.
    """
    browser = find()
    with tempfile.TemporaryDirectory(prefix="jpx-chrome-") as scratch:
        made = Path(scratch) / ("out" + out.suffix)
        command = [browser, *_QUIET, "--user-data-dir=" + str(Path(scratch) / "profile"), *extra, flag + str(made), html.resolve().as_uri()]
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + timeout
            last_size, stable = -1, 0
            while time.monotonic() < deadline and stable < 3:
                size = made.stat().st_size if made.exists() else -1
                stable = stable + 1 if size > 0 and size == last_size else 0
                last_size = size
                if process.poll() is not None and size > 0:
                    break
                if process.poll() is not None and size <= 0:
                    raise BrochureError("Chrome exited with status %s without writing %s" % (process.returncode, out.name))
                time.sleep(0.4)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if not made.exists() or made.stat().st_size == 0:
            raise BrochureError("Chrome did not produce %s within %d s" % (out.name, timeout))
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(made), str(out))


def to_pdf(html: Path, pdf: Path, timeout: float = 180) -> None:
    _run("--print-to-pdf=", ["--no-pdf-header-footer"], html, pdf, timeout)


def to_png(html: Path, png: Path, width: int, height: int, timeout: float = 120) -> None:
    _run("--screenshot=", ["--window-size=%d,%d" % (width, height)], html, png, timeout)


_SWIFT = Path(__file__).resolve().parent.parent / "pdf_pages.swift"


def pdf_to_images(pdf: Path, out_dir: Path, width: int = 1000) -> List[Path]:
    """One JPEG per PDF page, for looking at the result. Returns the page files in order."""
    with tempfile.TemporaryDirectory(prefix="jpx-pages-") as scratch:
        pdftoppm = shutil.which("pdftoppm")
        if pdftoppm:
            subprocess.run(
                [pdftoppm, "-jpeg", "-scale-to-x", str(width), "-scale-to-y", "-1", str(pdf), str(Path(scratch) / "raw")], check=True
            )
            made = sorted(Path(scratch).glob("raw-*.jpg"), key=lambda p: int(p.stem.split("-")[-1]))
        elif shutil.which("swift") and _SWIFT.exists():
            subprocess.run(["swift", str(_SWIFT), str(pdf), scratch, str(width)], check=True, stdout=subprocess.DEVNULL)
            made = sorted(Path(scratch).glob("page-*.jpg"))
        else:
            raise BrochureError(
                "cannot turn PDF pages into images: install poppler (pdftoppm), or on macOS the Swift toolchain. "
                "Review %s in a PDF viewer instead." % pdf
            )
        out_dir.mkdir(parents=True, exist_ok=True)
        # Pages of an earlier, longer build must not survive beside this one's.
        for stale in out_dir.glob("page-*.jpg"):
            stale.unlink()
        pages = []
        for number, path in enumerate(made, start=1):
            target = out_dir / ("page-%03d.jpg" % number)
            shutil.move(str(path), str(target))
            pages.append(target)
    return pages
