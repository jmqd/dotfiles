"""Command-line interface for building a listing brochure."""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path
from typing import List

import chrome
import draft
import ingest
import maps
import photos
import render
import sheets
from net import Disallowed, FetchFailed, Fetcher
from store import BrochureError, Folder, default_home, read_json, slugify


def _folder(args: argparse.Namespace) -> Folder:
    return Folder(Path(args.dir).expanduser())


def _cmd_new(args: argparse.Namespace) -> int:
    home = Path(args.home).expanduser() if args.home else default_home()
    folder = Folder(home / "brochures" / slugify(args.name))
    folder.capture_dir.mkdir(parents=True, exist_ok=True)
    print(folder.path)
    return 0


def _cmd_ingest(args: argparse.Namespace) -> int:
    folder = _folder(args)
    listing = ingest.merge(folder)
    categories = Counter(p["category"] or "(none)" for p in listing["photos"])
    print("listing: %s" % folder.listing)
    print("pages %d, fields %d, text blocks %d, photos %d (site furniture skipped: %d)" % (
        len(listing["pages"]), len(listing["pairs"]), len(listing["blocks"]), len(listing["photos"]), listing["furniture_images_skipped"]))
    print("photo categories: " + ", ".join("%s ×%d" % (c, n) for c, n in categories.most_common()))
    if listing["coords"]:
        first = listing["coords"][0]
        print("coordinates on the page: %.6f, %.6f (%s)" % (first["lat"], first["lon"], first.get("datum", "unknown")))
    else:
        print("coordinates on the page: none; pass --address or --lat/--lon to `maps`")
    for sub in listing["uncaptured_subpages"]:
        print("sub-page not captured: %s  (%s)" % (sub["url"], sub["text"].replace("\n", " ")))
    for pdf in listing["pdfs"]:
        print("PDF linked: %s  (%s)" % (pdf["url"], pdf.get("text", "")))
    return 0


def _cmd_photos(args: argparse.Namespace) -> int:
    folder = _folder(args)
    counts = photos.download(folder, Fetcher(delay_seconds=args.delay))
    print("photos: %d downloaded, %d already on disk, %d duplicates, %d failed" % (
        counts["ok"], counts["kept"], counts["duplicate"], counts["failed"]))
    records = (read_json(folder.photos) or {"photos": []})["photos"]
    small = [p for p in records if p.get("status") == "ok" and max(p["width"], p["height"]) < 600]
    if small:
        print("smaller than 600 px on the long side (a larger version may exist): " + ", ".join(p["id"] for p in small))
    for record in records:
        if record.get("status") == "failed":
            print("failed %s (%s): %s" % (record["id"], record.get("category") or "no category", "; ".join(record["errors"])[:200]))
    if counts["failed"]:
        print("save the failed photos from the browser and register each with `brochure add-photo <dir> <file> --id <id>`")
    return 0


def _cmd_add_photo(args: argparse.Namespace) -> int:
    record = photos.add(_folder(args), Path(args.file).expanduser(), args.id, args.category or "", args.caption or "")
    print("%s: %s (%d×%d)" % (record["id"], record["file"], record["width"], record["height"]))
    return 0


def _cmd_sheets(args: argparse.Namespace) -> int:
    for path in sheets.build(_folder(args)):
        print(path)
    return 0


def _cmd_maps(args: argparse.Namespace) -> int:
    folder = _folder(args)
    fetcher = Fetcher(delay_seconds=0.3)
    if args.lat is not None and args.lon is not None:
        lat, lon, source = args.lat, args.lon, "given on the command line"
    elif args.address:
        hit = maps.geocode(fetcher, args.address)
        lat, lon = hit["lat"], hit["lon"]
        source = "GSI geocoder, centre of %s (district precision)" % hit["matched"]
    else:
        listing = folder.require(folder.listing, "run `brochure ingest` first")
        if not listing["coords"]:
            raise BrochureError("the listing page exposes no coordinates; pass --address '<Japanese address>' or --lat and --lon")
        lat, lon = listing["coords"][0]["lat"], listing["coords"][0]["lon"]
        source = "the listing page's own map"
    made = maps.build(folder, lat, lon, source, tuple(args.view or maps.DEFAULT_VIEWS), fetcher)
    print("coordinates: %.6f, %.6f from %s" % (lat, lon, source))
    for item in made:
        print("map %-7s zoom %d, %.0f m across, %d tiles" % (item["id"], item["zoom"], item["width_m"], len(item["tiles"])))
    return 0


def _cmd_draft(args: argparse.Namespace) -> int:
    folder = _folder(args)
    content = draft.build(folder, overwrite=args.overwrite)
    print("draft: %s (%d sections, %d strings to translate)" % (
        folder.content, len(content["sections"]), len(render.untranslated(content))))
    return 0


def _cmd_build(args: argparse.Namespace) -> int:
    folder = _folder(args)
    checked = render.build(folder)
    print("html: %s" % folder.html)
    for warning in checked.warnings:
        print("warning: " + warning)
    if args.html_only:
        return 0
    chrome.to_pdf(folder.html, folder.pdf)
    pages = chrome.pdf_to_images(folder.pdf, folder.pages_dir, args.page_width)
    print("pdf: %s (%d pages, %.1f MB)" % (folder.pdf, len(pages), folder.pdf.stat().st_size / 1e6))
    print("page images: %s/page-001.jpg … page-%03d.jpg" % (folder.pages_dir, len(pages)))
    return 0


def _cmd_status(args: argparse.Namespace) -> int:
    folder = _folder(args)
    captures = sorted(folder.capture_dir.glob("*.json")) if folder.capture_dir.exists() else []
    print("captures: %d" % len(captures))
    listing = read_json(folder.listing)
    print("listing.json: " + ("%d fields, %d photos" % (len(listing["pairs"]), len(listing["photos"])) if listing else "missing"))
    records = (read_json(folder.photos) or {"photos": []})["photos"]
    states = Counter(p.get("status") for p in records)
    print("photos.json: " + (", ".join("%s %d" % (k, v) for k, v in sorted(states.items())) or "missing"))
    print("maps: " + (", ".join(m["id"] for m in (read_json(folder.maps) or {"maps": []})["maps"]) or "none"))
    left = render.unplaced(folder)
    print("brochure.json: " + ("missing" if left is None else "%d photos not yet placed or omitted%s" % (len(left), ": " + ", ".join(left) if left else "")))
    print("brochure.pdf: " + ("%.1f MB" % (folder.pdf.stat().st_size / 1e6) if folder.pdf.exists() else "missing"))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="brochure", description="Build an English PDF brochure from one Japanese property listing.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("new", help="create a brochure folder and print its path")
    p.add_argument("name", help="short name, e.g. minami-ogikubo-rc")
    p.add_argument("--home", help="workspace directory (default: $JP_PROPERTY_HOME or ~/japan-property)")
    p.set_defaults(func=_cmd_new)

    def with_dir(name: str, help_text: str) -> argparse.ArgumentParser:
        command = sub.add_parser(name, help=help_text)
        command.add_argument("dir", help="the brochure folder")
        return command

    p = with_dir("ingest", "merge capture/*.json into listing.json")
    p.set_defaults(func=_cmd_ingest)

    p = with_dir("photos", "download every photo at the largest size the site stores")
    p.add_argument("--delay", type=float, default=1.0, help="seconds between requests to one host (default 1.0)")
    p.set_defaults(func=_cmd_photos)

    p = with_dir("add-photo", "register an image obtained another way")
    p.add_argument("file")
    p.add_argument("--id", help="fill in this listing photo; omit to add an extra photo (x001, ...)")
    p.add_argument("--category", help="what the image shows, in the listing's words if it has any")
    p.add_argument("--caption")
    p.set_defaults(func=_cmd_add_photo)

    p = with_dir("sheets", "render contact sheets of the downloaded photos")
    p.set_defaults(func=_cmd_sheets)

    p = with_dir("maps", "download an aerial photo and an area map around the property")
    p.add_argument("--lat", type=float)
    p.add_argument("--lon", type=float)
    p.add_argument("--address", help="Japanese address to geocode when the page has no coordinates")
    p.add_argument("--view", action="append", choices=sorted(maps.VIEWS), help="repeatable; default: aerial and area")
    p.set_defaults(func=_cmd_maps)

    p = with_dir("draft", "write a first brochure.json with every Japanese string marked 'JA: '")
    p.add_argument("--overwrite", action="store_true", help="replace an existing brochure.json")
    p.set_defaults(func=_cmd_draft)

    p = with_dir("build", "check brochure.json, then write brochure.html, brochure.pdf and page images")
    p.add_argument("--html-only", action="store_true", help="stop after brochure.html")
    p.add_argument("--page-width", type=int, default=1000, help="pixel width of the review images (default 1000)")
    p.set_defaults(func=_cmd_build)

    p = with_dir("status", "show which steps are done")
    p.set_defaults(func=_cmd_status)
    return parser


def main(argv: List[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (BrochureError, Disallowed, FetchFailed) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
