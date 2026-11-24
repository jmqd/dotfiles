"""Behaviour of the brochure tools, driven through their public functions.

No test touches the network: downloads go through a stand-in for the fetcher.

Run: python3 -m unittest discover -s <skill>/tests
"""

from __future__ import annotations

import contextlib
import io
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "brochure"))

import cli  # noqa: E402
import draft  # noqa: E402
import imagesize  # noqa: E402
import ingest  # noqa: E402
import maps  # noqa: E402
import photos  # noqa: E402
import render  # noqa: E402
from net import Disallowed, FetchFailed  # noqa: E402
from store import BrochureError, Folder, read_json, write_json  # noqa: E402

LISTING_URL = "https://portal.example/chukoikkodate/tokyo/nc_20645338/"


def png(width: int, height: int, salt: bytes = b"") -> bytes:
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", width, height) + b"\x08\x02\x00\x00\x00" + salt


def jpeg(width: int, height: int) -> bytes:
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
    frame = b"\xff\xc0" + struct.pack(">HBHH", 17, 8, height, width) + b"\x03" + b"\x00" * 9
    return b"\xff\xd8" + app0 + frame


def gif(width: int, height: int) -> bytes:
    return b"GIF89a" + struct.pack("<HH", width, height) + b"\x00" * 4


def webp(width: int, height: int) -> bytes:
    canvas = (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
    return b"RIFF" + struct.pack("<I", 22) + b"WEBP" + b"VP8X" + struct.pack("<I", 10) + b"\x00" * 4 + canvas


class ReadingImageSizes(unittest.TestCase):
    def test_each_format_a_listing_uses_reports_its_pixel_size(self) -> None:
        cases = {"jpg": jpeg(854, 570), "png": png(1000, 750), "gif": gif(84, 84), "webp": webp(600, 400)}
        sizes = {kind: imagesize.dimensions(data) for kind, data in cases.items()}
        self.assertEqual(sizes, {"jpg": (854, 570, "jpg"), "png": (1000, 750, "png"), "gif": (84, 84, "gif"), "webp": (600, 400, "webp")})

    def test_an_error_page_served_in_place_of_a_photo_is_not_an_image(self) -> None:
        self.assertIsNone(imagesize.dimensions(b"<html><body>Not found</body></html>"))


class FolderCase(unittest.TestCase):
    """A brochure folder in a temporary directory."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Folder(Path(tmp.name))
        self.folder.capture_dir.mkdir(parents=True)

    def capture(self, name: str, **fields: object) -> None:
        page = {"url": LISTING_URL, "title": "t", "h1": "h", "captured_at": "2026-11-25T00:00:00Z", "pairs": [], "blocks": [], "images": [],
                "coords": [], "subpages": [], "pdfs": []}
        page.update(fields)
        write_json(self.folder.capture_dir / name, page)


def image(url: str, best: Optional[str] = None, **fields: object) -> dict:
    record = {"url": url, "candidates": [best, url] if best else [url], "alt": "", "category": "", "caption": "", "section": "", "w": 0, "h": 0}
    record.update(fields)
    return record


class MergingTheCapturedPages(FolderCase):
    def test_pages_merge_into_one_record_without_repeating_fields_or_photos(self) -> None:
        full = "https://img.example/front/20645338_0001.jpg"
        self.capture(
            "01-main.json",
            pairs=[{"label": "価格", "value": "4億8800万円", "section": "物件概要"}],
            images=[
                image("https://img.example/resize?src=20645338_0001.jpg&w=84", full, w=84, h=63),
                image(full, None, category="現地外観写真", caption="南側から撮影", w=1000, h=750),
                image("https://portal.example/img/logo.png", None, chrome=True),
            ],
            coords=[{"lat": 35.69819, "lon": 139.6151, "datum": "wgs84"}],
            subpages=[{"url": LISTING_URL + "kankyo/", "text": "周辺環境"}, {"url": LISTING_URL + "setsubi/", "text": "設備"}],
        )
        self.capture(
            "02-kankyo.json",
            url=LISTING_URL + "kankyo/",
            pairs=[{"label": "価格", "value": "4億8800万円"}, {"label": "学区", "value": "桃井第二小学校"}],
            images=[image("https://img.example/front/20645338_0021.jpg", None, category="スーパー")],
        )
        listing = ingest.merge(self.folder)
        self.assertEqual([(p["label"], p["page"]) for p in listing["pairs"]], [("価格", 1), ("学区", 2)])
        self.assertEqual(
            [(p["id"], p["category"], p["caption"], p["page_pixels"]) for p in listing["photos"]],
            [("p001", "現地外観写真", "南側から撮影", 750_000), ("p002", "スーパー", "", 0)],
        )
        self.assertEqual(listing["furniture_images_skipped"], 1)
        self.assertEqual(listing["coords"][0]["lat"], 35.69819)
        self.assertEqual([s["url"] for s in listing["uncaptured_subpages"]], [LISTING_URL + "setsubi/"])

    def test_photos_of_other_properties_on_the_page_are_set_aside(self) -> None:
        own = [image("https://img.example/front/20645338_%04d.jpg" % n) for n in range(1, 5)]
        others = [image("https://img.example/front/77700001_0001.jpg", None, category="おすすめ物件")]
        self.capture("01-main.json", images=own + others)
        listing = ingest.merge(self.folder)
        self.assertEqual(len(listing["photos"]), 4)
        self.assertEqual([o["url"] for o in listing["other_images"]], ["https://img.example/front/77700001_0001.jpg"])

    def test_an_image_that_only_echoes_the_page_address_is_not_one_of_the_listing_s_photos(self) -> None:
        echo = "?p=https%3A%2F%2Fportal.example%2Fchukoikkodate%2Ftokyo%2Fnc_20645338%2F"
        own = [image("https://img.example/front/20645338_%04d.jpg" % n) for n in range(1, 4)]
        resized = image("https://img.example/resize?src=front%2F20645338_0009.jpg&w=640")
        pixel = image("https://ads.example/action/0" + echo, None, how="img", shown="0x0")
        banner = image("https://ads.example/banner" + echo, None, how="img", w=300, h=250, shown="300x250")
        self.capture("01-main.json", images=own + [resized, pixel, banner])
        listing = ingest.merge(self.folder)
        self.assertEqual([p["url"] for p in listing["photos"]], [p["url"] for p in own] + [resized["url"]])
        self.assertEqual([o["url"] for o in listing["other_images"]], [banner["url"]])
        self.assertEqual(listing["furniture_images_skipped"], 1)

    def test_a_photo_id_never_comes_to_name_another_photo(self) -> None:
        def ids() -> Dict[str, str]:
            return {p["url"].rsplit("_", 1)[1]: p["id"] for p in ingest.merge(self.folder)["photos"]}

        front = "https://img.example/front/20645338_%s.jpg"
        self.capture("01-main.json", images=[image(front % "0001"), image(front % "0002"), image(front % "0003")])
        self.capture("03-setsubi.json", url=LISTING_URL + "setsubi/", images=[image(front % "0030")])
        self.assertEqual(ids(), {"0001.jpg": "p001", "0002.jpg": "p002", "0003.jpg": "p003", "0030.jpg": "p004"})
        # A page captured afterwards sorts before the last one. Its photo takes a new id, not that page's.
        self.capture("02-kankyo.json", url=LISTING_URL + "kankyo/", images=[image(front % "0020")])
        self.assertEqual(ids(), {"0001.jpg": "p001", "0002.jpg": "p002", "0003.jpg": "p003", "0020.jpg": "p005", "0030.jpg": "p004"})
        # The page is captured again after the agent swapped that photo: the id of the one that is gone is not handed on.
        self.capture("02-kankyo.json", url=LISTING_URL + "kankyo/", images=[image(front % "0021")])
        self.assertEqual(ids(), {"0001.jpg": "p001", "0002.jpg": "p002", "0003.jpg": "p003", "0021.jpg": "p006", "0030.jpg": "p004"})

    def test_the_same_house_on_a_second_site_adds_its_photos(self) -> None:
        own = [image("https://img.example/front/20645338_%04d.jpg" % n) for n in range(1, 5)]
        self.capture("01-main.json", images=own + [image("https://img.example/front/77700001_0001.jpg")])
        elsewhere = [image("https://cdn.agency.example/house/b0024878071/%02d.jpg" % n) for n in range(1, 4)]
        self.capture("05-main.json", url="https://agency.example/house/b0024878071/", images=elsewhere)
        listing = ingest.merge(self.folder)
        self.assertEqual([(p["id"], p["page"]) for p in listing["photos"]][-3:], [("p005", 2), ("p006", 2), ("p007", 2)])
        self.assertEqual(len(listing["other_images"]), 1)
        self.assertEqual(listing["url"], LISTING_URL)

    def test_a_block_page_is_refused_instead_of_becoming_an_empty_brochure(self) -> None:
        self.capture("01-main.json", blocked=["captcha"])
        with self.assertRaisesRegex(BrochureError, "block page"):
            ingest.merge(self.folder)


Reply = Union[bytes, Exception]


class FakeFetcher:
    """Stands in for the network: answers each URL with the bytes or the failure given for it."""

    def __init__(self, replies: Dict[str, Reply]) -> None:
        self.replies = replies
        self.asked: List[str] = []

    def get(self, url: str, referer: Optional[str] = None) -> Tuple[str, bytes]:
        self.asked.append(url)
        reply = self.replies.get(url, FetchFailed("%s returned HTTP 404" % url))
        if isinstance(reply, Exception):
            raise reply
        return "image/png", reply


class DownloadingThePhotos(FolderCase):
    def listing(self, *entries: dict) -> None:
        listed = []
        for number, entry in enumerate(entries, start=1):
            base = {"id": "p%03d" % number, "category": "", "caption": "", "section": "", "page": 1, "page_pixels": 0}
            listed.append(dict(base, **entry))
        write_json(self.folder.listing, {"url": LISTING_URL, "photos": listed})

    def records(self) -> Dict[str, dict]:
        return {p["id"]: p for p in read_json(self.folder.photos)["photos"]}

    def test_the_largest_version_is_saved_and_a_second_run_downloads_nothing(self) -> None:
        self.listing({"url": "https://i.example/a.jpg?w=188", "candidates": ["https://i.example/a.jpg", "https://i.example/a.jpg?w=188"]})
        fetcher = FakeFetcher({"https://i.example/a.jpg": png(1000, 750), "https://i.example/a.jpg?w=188": png(188, 141)})
        self.assertEqual(photos.download(self.folder, fetcher)["ok"], 1)
        saved = self.records()["p001"]
        self.assertEqual((saved["width"], saved["height"], saved["url"]), (1000, 750, "https://i.example/a.jpg"))
        self.assertEqual(imagesize.dimensions((self.folder.path / saved["file"]).read_bytes()), (1000, 750, "png"))
        again = FakeFetcher({})
        self.assertEqual(photos.download(self.folder, again), {"ok": 0, "kept": 1, "duplicate": 0, "failed": 0})
        self.assertEqual(again.asked, [])

    def test_a_guess_smaller_than_the_image_on_the_page_gives_way_to_the_page_s_own(self) -> None:
        self.listing({"url": "https://i.example/a.jpg?w=640", "candidates": ["https://i.example/a.jpg", "https://i.example/a.jpg?w=640"], "page_pixels": 640 * 480})
        fetcher = FakeFetcher({"https://i.example/a.jpg": png(1, 1), "https://i.example/a.jpg?w=640": png(640, 480)})
        photos.download(self.folder, fetcher)
        self.assertEqual(self.records()["p001"]["url"], "https://i.example/a.jpg?w=640")

    def test_a_placeholder_served_for_every_guess_never_stands_in_for_a_photo(self) -> None:
        placeholder = png(640, 640, b"no image")
        self.listing(
            {"url": "https://i.example/a.jpg?w=188", "candidates": ["https://i.example/a.jpg?w=1600", "https://i.example/a.jpg?w=188"]},
            {"url": "https://i.example/b.jpg?w=188", "candidates": ["https://i.example/b.jpg?w=1600", "https://i.example/b.jpg?w=188"]},
        )
        fetcher = FakeFetcher({
            "https://i.example/a.jpg?w=1600": placeholder, "https://i.example/b.jpg?w=1600": placeholder,
            "https://i.example/a.jpg?w=188": png(188, 141, b"a"), "https://i.example/b.jpg?w=188": png(188, 141, b"b"),
        })
        counts = photos.download(self.folder, fetcher)
        self.assertEqual((counts["ok"], counts["failed"]), (2, 0))
        saved = self.records()
        # The first photo took the placeholder before it could be recognised; it is fetched again as the page had it.
        self.assertEqual({pid: r["url"] for pid, r in saved.items()}, {"p001": "https://i.example/a.jpg?w=188", "p002": "https://i.example/b.jpg?w=188"})
        self.assertNotEqual(saved["p001"]["sha256"], saved["p002"]["sha256"])

    def test_the_same_picture_listed_twice_is_recorded_once(self) -> None:
        self.listing({"url": "https://i.example/a.jpg", "candidates": ["https://i.example/a.jpg"]}, {"url": "https://i.example/a2.jpg", "candidates": ["https://i.example/a2.jpg"]})
        same = png(800, 600)
        counts = photos.download(self.folder, FakeFetcher({"https://i.example/a.jpg": same, "https://i.example/a2.jpg": same}))
        self.assertEqual((counts["ok"], counts["duplicate"]), (1, 1))
        self.assertEqual(self.records()["p002"]["duplicate_of"], "p001")

    def test_a_photo_that_may_not_or_cannot_be_downloaded_is_reported_not_dropped(self) -> None:
        self.listing({"url": "https://closed.example/a.jpg", "candidates": ["https://closed.example/a.jpg"]}, {"url": "https://i.example/gone.jpg", "candidates": ["https://i.example/gone.jpg"]})
        fetcher = FakeFetcher({"https://closed.example/a.jpg": Disallowed("robots.txt disallows https://closed.example/a.jpg")})
        self.assertEqual(photos.download(self.folder, fetcher)["failed"], 2)
        saved = self.records()
        self.assertEqual((saved["p001"]["status"], saved["p001"]["disallowed"]), ("failed", True))
        self.assertEqual((saved["p002"]["status"], saved["p002"]["disallowed"]), ("failed", False))

    def test_a_photo_saved_by_hand_fills_the_gap_a_failed_download_left(self) -> None:
        self.listing({"url": "https://i.example/gone.jpg", "candidates": ["https://i.example/gone.jpg"], "category": "間取り図"})
        photos.download(self.folder, FakeFetcher({}))
        by_hand = self.folder.path / "saved.png"
        by_hand.write_bytes(png(1200, 900))
        record = photos.add(self.folder, by_hand, "p001", "", "")
        self.assertEqual((record["status"], record["category"], record["width"]), ("ok", "間取り図", 1200))
        with self.assertRaises(BrochureError):
            photos.add(self.folder, by_hand, "p999", "", "")

    def test_a_photo_the_listing_no_longer_has_is_forgotten_and_one_added_by_hand_is_kept(self) -> None:
        kept = {"url": "https://i.example/a.jpg", "candidates": ["https://i.example/a.jpg"]}
        self.listing(kept, {"url": "https://ads.example/pixel", "candidates": ["https://ads.example/pixel"]})
        photos.download(self.folder, FakeFetcher({"https://i.example/a.jpg": png(1000, 750)}))
        by_hand = self.folder.path / "survey.png"
        by_hand.write_bytes(png(1200, 900))
        extra = photos.add(self.folder, by_hand, None, "測量図", "")
        self.assertEqual(self.records()["p002"]["status"], "failed")
        # A later ingest sets the second image aside as not one of the listing's photos.
        self.listing(kept)
        self.assertEqual(photos.download(self.folder, FakeFetcher({})), {"ok": 0, "kept": 1, "duplicate": 0, "failed": 0})
        self.assertEqual(sorted(self.records()), ["p001", extra["id"]])


def content(**changes: object) -> dict:
    base = {
        "eyebrow": "Portal listing no. 20645338 · English translation",
        "title": "Reinforced-concrete house in Minami-Ogikubo",
        "short_name": "Minami-Ogikubo RC house",
        "source": {"site": "Portal", "url": LISTING_URL, "translated_on": "25 November 2026"},
        "hero_photo": "p001",
        "key_facts": [{"label": "Price", "value": "¥488,000,000"}, {"label": "Land", "value": "409.22 m²"}, {"label": "Building", "value": "540.53 m²"}],
        "sections": [
            {"type": "table", "title": "Property details", "rows": [{"label": "Price", "value": "¥488,000,000", "ja_label": "価格", "ja": "4億8800万円"}]},
            {"type": "photos", "title": "Photos", "items": [{"photo": "p002", "label": "Living room", "caption": "First floor."}]},
        ],
    }
    base.update(changes)
    return base


class CheckingTheBrochureBeforeItIsBuilt(FolderCase):
    def setUp(self) -> None:
        super().setUp()
        write_json(self.folder.listing, {"url": LISTING_URL, "pairs": [{"label": "価格", "value": "4億8800万円"}, {"label": "構造・工法", "value": "RC3階建"}], "photos": []})
        ok = {"status": "ok", "width": 1000, "height": 750, "category": "", "errors": []}
        write_json(self.folder.photos, {"photos": [dict(ok, id="p001", file="photos/p001.jpg"), dict(ok, id="p002", file="photos/p002.jpg")]})

    def problems(self, **changes: object) -> str:
        write_json(self.folder.content, content(**changes))
        with self.assertRaises(BrochureError) as caught:
            render.check(self.folder)
        return str(caught.exception)

    def test_a_complete_translation_becomes_a_page_with_every_photo_placed(self) -> None:
        write_json(self.folder.content, content(ignored_labels=["構造・工法"]))
        checked = render.build(self.folder)
        self.assertEqual(checked.warnings, [])
        page = self.folder.html.read_text(encoding="utf-8")
        for expected in ("Reinforced-concrete house in Minami-Ogikubo", "photos/p001.jpg", "photos/p002.jpg", "4億8800万円", LISTING_URL):
            self.assertIn(expected, page)

    def test_a_photo_neither_placed_nor_explained_stops_the_build(self) -> None:
        self.assertIn("photo p002", self.problems(sections=[content()["sections"][0]]))
        write_json(self.folder.content, content(sections=[content()["sections"][0]], omitted_photos=[{"photo": "p002", "reason": "the agent's gift promotion"}]))
        render.check(self.folder)

    def test_text_left_in_japanese_by_the_draft_stops_the_build(self) -> None:
        self.assertIn("untranslated", self.problems(title=draft.DRAFT_PREFIX + "ＲＣ造×注文住宅"))

    def test_a_photo_the_listing_does_not_have_stops_the_build(self) -> None:
        self.assertIn("'p404'", self.problems(hero_photo="p404"))

    def test_a_listing_field_that_no_row_names_is_warned_about(self) -> None:
        write_json(self.folder.content, content())
        warnings = render.check(self.folder).warnings
        self.assertEqual(len(warnings), 1)
        self.assertIn("構造・工法", warnings[0])

    def test_one_label_written_in_full_or_half_width_counts_as_named(self) -> None:
        write_json(self.folder.listing, {"url": LISTING_URL, "pairs": [{"label": "完成時期（築年月）", "value": "2006年6月"}], "photos": []})
        rows = [{"label": "Built", "value": "June 2006", "ja_label": "完成時期(築年月)"}]
        write_json(self.folder.content, content(sections=[{"type": "table", "title": "Details", "rows": rows}, content()["sections"][1]]))
        self.assertEqual(render.check(self.folder).warnings, [])


class AskingRobotsTxtBeforeReadingTheListing(FolderCase):
    def verdicts(self, status: int, text: str, *urls: str) -> Tuple[int, List[str]]:
        write_json(self.folder.robots, {"origin": "https://portal.example", "status": status, "text": text})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["allowed", str(self.folder.path)] + list(urls))
        return code, out.getvalue().splitlines()

    def test_a_listing_the_site_keeps_automated_visitors_out_of_is_refused(self) -> None:
        rules = "User-agent: *\nDisallow: /chukoikkodate/*/kankyo/"
        code, lines = self.verdicts(200, rules, LISTING_URL, LISTING_URL + "kankyo/")
        self.assertEqual(code, 1)
        self.assertEqual([line.split(" ")[0] for line in lines], ["allow", "DISALLOW"])

    def test_a_site_that_names_the_assistant_is_closed_whatever_it_allows_others(self) -> None:
        code, lines = self.verdicts(200, "User-agent: *\nAllow: /\n\nUser-agent: ClaudeBot\nDisallow: /", LISTING_URL)
        self.assertEqual((code, lines[0].split(" ")[0]), (1, "DISALLOW"))

    def test_no_robots_txt_permits_and_an_unreadable_one_refuses(self) -> None:
        self.assertEqual(self.verdicts(404, "", LISTING_URL)[0], 0)
        self.assertEqual(self.verdicts(403, "<html>Forbidden</html>", LISTING_URL)[0], 1)

    def test_a_page_on_another_host_is_not_covered_by_the_robots_txt_on_file(self) -> None:
        self.assertEqual(self.verdicts(404, "", "https://other.example/listing/1")[0], 1)


class PlacingTheMapOnTheGround(unittest.TestCase):
    def test_tokyo_station_falls_in_its_known_tile(self) -> None:
        x, y = maps.tile_position(35.681236, 139.767125, 16)
        self.assertEqual((int(x), int(y)), (58211, 25806))

    def test_a_tile_covers_less_ground_further_north(self) -> None:
        self.assertLess(maps.metres_per_pixel(43.06, 16), maps.metres_per_pixel(26.21, 16))
        self.assertAlmostEqual(maps.metres_per_pixel(35.68, 18) * 256, 124.2, delta=0.5)


class DraftingFromTheListing(FolderCase):
    def test_the_draft_marks_every_japanese_string_and_places_every_photo(self) -> None:
        write_json(self.folder.listing, {
            "url": LISTING_URL, "title": "ＲＣ造×注文住宅", "h1": "ＲＣ造×注文住宅", "captured_at": "2026-11-25T00:00:00Z",
            "pairs": [{"label": "価格", "value": "4億8800万円", "section": "物件概要", "page": 1}],
            "blocks": [], "coords": [], "pdfs": [], "pages": [],
            "photos": [{"id": "p001", "url": "u", "candidates": ["u"], "category": "現地外観写真", "caption": "", "section": "", "page": 1}],
        })
        write_json(self.folder.photos, {"photos": [{"id": "p001", "status": "ok", "file": "photos/p001.jpg", "width": 1000, "height": 750, "category": "現地外観写真"}]})
        drafted = draft.build(self.folder)
        self.assertTrue(render.untranslated(drafted))
        self.assertEqual(render.unplaced(self.folder), [])
        with self.assertRaisesRegex(BrochureError, "untranslated"):
            render.check(self.folder)


if __name__ == "__main__":
    unittest.main()
