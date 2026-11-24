"""Behaviour of the property search tools, driven through their public functions.

Run: python3 -m unittest discover -s <skill>/tests
"""

from __future__ import annotations

import datetime
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "jpsearch"))

import criteria  # noqa: E402
import dedupe  # noqa: E402
import listings  # noqa: E402
import plan as planning  # noqa: E402
import registry  # noqa: E402
import robots  # noqa: E402
import state as state_store  # noqa: E402
import text  # noqa: E402
from workspace import Workspace, write_json  # noqa: E402

PROFILE = criteria.parse_profile(
    {
        "name": "test",
        "listing_types": ["used_house"],
        "building_m2_min": 250,
        "structures": ["RC", "SRC"],
        "near_miss_percent": 10,
        "zones": [
            {"id": "tokyo-23", "prefecture": "東京都", "municipality_suffix": "区", "land_m2_min": 190},
            {"id": "elsewhere", "land_m2_min": 1000},
        ],
    }
)


def pairs(**fields: str) -> list:
    return [{"label": label, "value": value} for label, value in fields.items()]


def listing(url: str = "https://example.jp/1", source: str = "a", title: str = "", **fields: str) -> dict:
    return listings.normalise(source, "used_house", url, title, pairs(**fields), None, None, "2026-11-25")


class ReadingListingText(unittest.TestCase):
    def test_prices_in_every_form_portals_write_them(self) -> None:
        cases = {
            "4億8800万円": 488_000_000,
            "4億8,800万円": 488_000_000,
            "３億９８００万円": 398_000_000,
            "1億円": 100_000_000,
            "9,800万円": 98_000_000,
            "2.5億円": 250_000_000,
            "1億2千万円": 120_000_000,
            "¥488,000,000": 488_000_000,
            "488,000,000円": 488_000_000,
            "488 million yen": 488_000_000,
            "5,480万円 坪単価150万円": 54_800_000,
        }
        for written, expected in cases.items():
            with self.subTest(written):
                self.assertEqual(text.parse_price(written).low, expected)

    def test_a_price_range_keeps_both_ends(self) -> None:
        price = text.parse_price("1億2000万円〜1億5000万円")
        self.assertEqual((price.low, price.high), (120_000_000, 150_000_000))

    def test_price_on_request_is_undisclosed_not_missing(self) -> None:
        self.assertTrue(text.parse_price("価格応談").undisclosed)
        self.assertIsNone(text.parse_price("-"))

    def test_areas_take_the_total_not_the_itemised_parts(self) -> None:
        cases = {
            "409.22m2（123.78坪）（登記）": 409.22,
            "540.53㎡": 540.53,
            "1,003.5m²": 1003.5,
            "２５０．５㎡": 250.5,
            "391.2㎡（118.33坪）（登記）、うち地下室104.24m2": 391.2,
            "287.68m2、うち地下室30.61m2、１階車庫49.8m2": 287.68,
            "1,234 sq m": 1234.0,
        }
        for written, expected in cases.items():
            with self.subTest(written):
                self.assertAlmostEqual(text.parse_area(written).m2, expected)

    def test_an_area_given_only_in_tsubo_is_converted(self) -> None:
        area = text.parse_area("約300坪")
        self.assertTrue(area.from_tsubo)
        self.assertAlmostEqual(area.m2, 991.74, places=1)

    def test_build_dates_in_western_and_era_years(self) -> None:
        today = datetime.date(2026, 11, 25)
        cases = {
            "2006年6月": (2006, 6),
            "平成18年6月": (2006, 6),
            "昭和58年11月": (1983, 11),
            "令和元年": (2019, None),
            "H18.6築": (2006, 6),
            "June 2006": (2006, 6),
            "Built in 1997": (1997, None),
        }
        for written, expected in cases.items():
            with self.subTest(written):
                built = text.parse_built(written, today)
                self.assertEqual((built.year, built.month), expected)
        aged = text.parse_built("築35年", today)
        self.assertEqual((aged.year, aged.approximate), (1991, True))

    def test_structures_are_told_apart(self) -> None:
        cases = {
            "RC3階建": (text.RC, 3, None),
            "鉄筋コンクリート造陸屋根地下1階付3階建": (text.RC, 3, 1),
            "ＲＣ造地上2階地下1階建": (text.RC, 2, 1),
            "鉄筋ｺﾝｸﾘｰﾄ造": (text.RC, None, None),
            "鉄骨鉄筋コンクリート造": (text.SRC, None, None),
            "軽量鉄骨造2階建": (text.STEEL, 2, None),
            "木造2階建": (text.WOOD, 2, None),
            "鉄筋コンクリート造一部木造": (text.MIXED, None, None),
            "Reinforced Concrete": (text.RC, None, None),
        }
        for written, (kind, floors, basement) in cases.items():
            with self.subTest(written):
                s = text.parse_structure(written)
                self.assertEqual((s.kind, s.floors, s.basement), (kind, floors, basement))

    def test_rc_inside_another_word_is_not_a_structure(self) -> None:
        self.assertIsNone(text.parse_structure("ARCHITECT"))
        self.assertFalse(text.concrete_hint("ARCHITECT'S HOUSE"))

    def test_addresses_split_at_the_municipality(self) -> None:
        cases = {
            "東京都杉並区南荻窪１": ("東京都", "杉並区"),
            "山梨県北杜市長坂町白井沢": ("山梨県", "北杜市"),
            "長野県北佐久郡軽井沢町大字長倉": ("長野県", "北佐久郡軽井沢町"),
            "神奈川県横浜市青葉区美しが丘": ("神奈川県", "横浜市青葉区"),
            "三重県四日市市諏訪町": ("三重県", "四日市市"),
            "奈良県大和郡山市筒井町": ("奈良県", "大和郡山市"),
            "千葉県市川市八幡": ("千葉県", "市川市"),
            "東京都町田市玉川学園": ("東京都", "町田市"),
            "Minami-Azabu, Minato-ku, Tokyo": ("東京都", "港区"),
        }
        for written, expected in cases.items():
            with self.subTest(written):
                address = text.parse_address(written)
                self.assertEqual((address.prefecture, address.municipality), expected)

    def test_one_town_written_three_ways_has_one_key(self) -> None:
        keys = {text.town_key(t) for t in ("南荻窪１", "南荻窪1丁目", "南荻窪一丁目12-3")}
        self.assertEqual(keys, {"南荻窪1"})

    def test_label_with_tooltip_line_and_combined_labels_are_read(self) -> None:
        record = listings.normalise(
            "a", "used_house", "u", "",
            [
                {"label": "構造・工法\nヒント", "value": "RC3階建"},
                {"label": "土地面積/間取り", "value": "409.22m²\n5LDK"},
                {"label": "交通", "value": "ＪＲ中央線「荻窪」歩13分\n[ 乗り換え案内 ]"},
            ],
            None, None, "2026-11-25",
        )
        self.assertEqual((record["structure"], record["floors"]), (text.RC, 3))
        self.assertEqual((record["land_m2"], record["layout"]), (409.22, "5LDK"))
        self.assertNotIn("乗り換え案内", record["access"])

    def test_a_photo_category_beside_a_label_is_not_taken_as_its_value(self) -> None:
        record = listing(前面道路="周辺環境")
        self.assertIsNone(record["road"])

    def test_card_copy_naming_concrete_is_a_hint_not_the_structure(self) -> None:
        record = listings.normalise(
            "a", "used_house", "u", "RC造の車庫付き", [], "価格 9,800万円 土地 300m2 建物 260m2", None, "2026-11-25"
        )
        self.assertIsNone(record["structure"])
        self.assertTrue(record["concrete_hint"])
        self.assertEqual((record["price_jpy"], record["land_m2"], record["building_m2"]), (98_000_000, 300.0, 260.0))


class JudgingAgainstTheCriteria(unittest.TestCase):
    def house(self, address: str, land: str, building: str = "300m2", structure: str = "RC造") -> dict:
        fields = {"所在地": address, "土地面積": land, "建物面積": building}
        if structure:
            fields["構造"] = structure
        return listing(**fields)

    def status(self, record: dict) -> str:
        return criteria.judge(PROFILE, record).status

    def test_the_lot_minimum_depends_on_the_zone(self) -> None:
        self.assertEqual(self.status(self.house("東京都杉並区南荻窪1", "200m2")), criteria.MATCH)
        self.assertEqual(self.status(self.house("長野県北佐久郡軽井沢町長倉", "200m2")), criteria.REJECTED)
        self.assertEqual(self.status(self.house("長野県北佐久郡軽井沢町長倉", "1,200m2")), criteria.MATCH)
        self.assertEqual(self.status(self.house("東京都町田市玉川学園", "500m2")), criteria.REJECTED)

    def test_just_under_a_threshold_is_a_near_miss(self) -> None:
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "180m2")), criteria.NEAR_MISS)
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "170m2")), criteria.REJECTED)
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "200m2", building="230m2")), criteria.NEAR_MISS)

    def test_an_unstated_structure_is_unverified_not_rejected(self) -> None:
        verdict = criteria.judge(PROFILE, self.house("東京都港区南麻布3", "200m2", structure=""))
        self.assertEqual(verdict.status, criteria.UNVERIFIED)
        self.assertIn("structure not stated", verdict.reasons(criteria.UNKNOWN)[0])

    def test_wood_is_rejected_and_part_concrete_needs_review(self) -> None:
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "200m2", structure="木造2階建")), criteria.REJECTED)
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "200m2", structure="RC造一部木造")), criteria.NEAR_MISS)
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "200m2", structure="SRC造")), criteria.MATCH)

    def test_an_address_too_vague_for_a_zone_is_unverified_unless_too_small_everywhere(self) -> None:
        self.assertEqual(self.status(self.house("東京都", "300m2")), criteria.UNVERIFIED)
        self.assertEqual(self.status(self.house("東京都", "100m2")), criteria.REJECTED)

    def test_a_bigger_lot_never_turns_a_match_into_a_rejection(self) -> None:
        rng = random.Random(20261125)
        order = [criteria.REJECTED, criteria.NEAR_MISS, criteria.MATCH]
        for _ in range(200):
            address = rng.choice(["東京都杉並区南荻窪1", "長野県北佐久郡軽井沢町長倉"])
            small = rng.uniform(50, 2000)
            large = small + rng.uniform(0, 500)
            before = self.status(self.house(address, "%.2fm2" % small))
            after = self.status(self.house(address, "%.2fm2" % large))
            self.assertLessEqual(order.index(before), order.index(after), (address, small, large))

    def test_a_profile_without_a_catch_all_zone_is_refused(self) -> None:
        with self.assertRaises(criteria.ProfileError):
            criteria.parse_profile(
                {"building_m2_min": 250, "structures": ["RC"], "zones": [{"id": "t", "prefecture": "東京都", "land_m2_min": 190}]}
            )


class RecognisingOneHouseAcrossListings(unittest.TestCase):
    def same_house(self) -> list:
        base = {"所在地": "東京都杉並区南荻窪１", "土地面積": "409.22m2（登記）", "築年月": "2006年6月", "販売価格": "4億8800万円"}
        return [
            listing("https://suumo.jp/a", "suumo", "RC造×注文住宅", **dict(base, 建物面積="540.53m2")),
            listing("https://suumo.jp/b", "suumo", "Luxury Residence", **dict(base, 建物面積="540.53m2（登記）")),
            # Another agent quotes the measured floor area, not the registered one.
            listing("https://www.homes.co.jp/c", "homes", "絢爛な大邸宅", **dict(base, 建物面積="504.18m2（実測）", 所在地="東京都杉並区南荻窪1丁目")),
        ]

    def test_listings_by_different_agents_and_portals_are_one_property(self) -> None:
        groups = dedupe.cluster(self.same_house())
        self.assertEqual([len(g) for g in groups], [3])
        prop = dedupe.merge(groups[0])
        self.assertEqual(prop["building_m2"], 540.53)
        self.assertEqual(prop["sources"], ["homes", "suumo"])
        self.assertEqual(len(prop["urls"]), 3)

    def test_neighbours_with_different_areas_stay_separate(self) -> None:
        other = listing(
            "https://suumo.jp/z", "suumo", "",
            所在地="東京都杉並区南荻窪１", 土地面積="300.10m2", 建物面積="280.00m2", 築年月="2006年6月", 販売価格="4億8800万円",
        )
        self.assertEqual(sorted(len(g) for g in dedupe.cluster(self.same_house() + [other])), [1, 3])

    def test_same_areas_in_a_different_town_stay_separate(self) -> None:
        a = listing("https://x/1", 所在地="東京都世田谷区成城6", 土地面積="330.00m2", 建物面積="260.00m2")
        b = listing("https://x/2", 所在地="東京都世田谷区深沢6", 土地面積="330.00m2", 建物面積="260.00m2")
        self.assertEqual(len(dedupe.cluster([a, b])), 2)

    def test_grouping_does_not_depend_on_the_order_listings_arrive_in(self) -> None:
        records = self.same_house() + [
            listing("https://x/%d" % i, 所在地="東京都世田谷区成城%d" % (i % 4 + 1), 土地面積="%d.5m2" % (300 + i), 建物面積="%d.5m2" % (250 + i))
            for i in range(12)
        ]
        expected = sorted(sorted(l["url"] for l in g) for g in dedupe.cluster(records))
        rng = random.Random(7)
        for _ in range(20):
            rng.shuffle(records)
            self.assertEqual(sorted(sorted(l["url"] for l in g) for g in dedupe.cluster(records)), expected)


class HonouringRobotsTxt(unittest.TestCase):
    RULES = "\n".join(
        [
            "User-agent: *",
            "Disallow: /jj/bukken/ichiran/JJ012FC001/",
            "Disallow: /used/house/search/?",
            "Allow: /used/house/search/?cid=",
            "Disallow: /used/house/search/*?start=",
            "Disallow: /baikyaku/*/ek_*/$",
            "User-agent: bingbot",
            "Crawl-delay: 30",
            "Disallow: /",
        ]
    )

    def test_wildcards_anchors_and_longest_match(self) -> None:
        cases = {
            "https://s.jp/jj/bukken/ichiran/JJ012FC001/?ar=030": False,
            "https://s.jp/chukoikkodate/tokyo/sc_suginami/?hb=150&po=10": True,
            "https://s.jp/used/house/search/?pf=13": False,
            "https://s.jp/used/house/search/?cid=1": True,
            "https://s.jp/used/house/search/13/": True,
            "https://s.jp/used/house/search/13/?start=30": False,
            "https://s.jp/baikyaku/tokyo/ek_123/": False,
            "https://s.jp/baikyaku/tokyo/ek_123/more": True,
        }
        for url, expected in cases.items():
            with self.subTest(url):
                self.assertEqual(robots.allowed(self.RULES, url), expected)

    def test_another_crawlers_group_does_not_apply_to_us(self) -> None:
        self.assertTrue(robots.allowed(self.RULES, "https://s.jp/anything"))
        self.assertIsNone(robots.crawl_delay(self.RULES))
        self.assertEqual(robots.crawl_delay(self.RULES, "bingbot"), 30.0)

    def test_a_site_without_robots_txt_allows_everything(self) -> None:
        self.assertTrue(robots.allowed(None, "https://s.jp/x?y=1"))


REGISTRY = {
    "sources": [
        {
            "id": "demo",
            "name": "Demo",
            "kind": "portal",
            "home": "https://demo.example/",
            "searches": [
                {
                    "listing_type": "used_house",
                    "scope": "prefecture",
                    "url": "https://demo.example/{pref}/houses?bmin={building_min}&lmin={land_min}&sort=big&p={page}",
                    "building_min": [0, 100, 200],
                    "land_min": "free",
                    "sorted_by": "building_desc",
                    "per_page": 2,
                    "max_pages": 5,
                }
            ],
        },
        {"id": "byhand", "name": "By hand", "kind": "resort", "home": "https://hand.example/", "manual": "browse it"},
    ]
}


def card(n: int, building: float, land: float = 300.0, title: str = "") -> dict:
    return {
        "url": "https://demo.example/tokyo/h%d" % n,
        "title": title,
        "pairs": pairs(価格="2億円", 所在地="東京都港区南麻布%d" % n, 土地面積="%.2fm2" % land, 建物面積="%.2fm2" % building),
        "text": "",
        "image": None,
    }


class PlanningARun(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ws = Workspace(Path(self.tmp.name), "2026-11-25")
        self.profile = criteria.parse_profile(
            {
                "building_m2_min": 250, "structures": ["RC", "SRC"], "areas": ["東京都"],
                "zones": [
                    {"id": "tokyo-23", "prefecture": "東京都", "municipality_suffix": "区", "land_m2_min": 190},
                    {"id": "elsewhere", "land_m2_min": 1000},
                ],
            }
        )
        self.sources = registry.parse_registry(REGISTRY)

    def plan(self) -> dict:
        state = state_store.load(self.ws)
        return planning.Planner(self.ws, self.profile, self.sources, state).build()

    def todo(self) -> list:
        return [t for t in self.plan()["tasks"] if t["status"] == planning.TODO]

    def capture(self, task: dict, result: dict, error: str = None) -> None:
        write_json(self.ws.home / task["out"], {"task": task, "fetched_at": "t", "error": error, "result": result})

    def test_nothing_is_fetched_before_robots_txt(self) -> None:
        tasks = self.plan()["tasks"]
        self.assertEqual([(t["kind"], t["status"]) for t in tasks], [("robots", "todo"), ("list", "waiting")])

    def test_the_server_filter_is_the_tightest_value_that_hides_nothing(self) -> None:
        self.capture(self.todo()[0], {"status": 404, "text": ""})
        # Building options stop at 200 (floor is 225); land is free, so the near-miss floor 171 is sent.
        self.assertEqual(self.todo()[0]["url"], "https://demo.example/tokyo/houses?bmin=200&lmin=171&sort=big&p=1")

    def test_disallowed_urls_are_never_planned_for_fetching(self) -> None:
        self.capture(self.todo()[0], {"status": 200, "text": "User-agent: *\nDisallow: /tokyo/houses"})
        tasks = self.plan()["tasks"]
        self.assertEqual(self.todo(), [])
        self.assertEqual([t["status"] for t in tasks if t["kind"] == "list"], ["disallowed"])

    def test_an_unreadable_robots_txt_closes_the_host(self) -> None:
        self.capture(self.todo()[0], {"status": 403, "text": "<html>Forbidden</html>"})
        tasks = self.plan()["tasks"]
        self.assertEqual(self.todo(), [])
        self.assertIn("HTTP 403", [t for t in tasks if t["kind"] == "list"][0]["why"])

    def test_paging_stops_below_the_size_threshold_and_details_follow(self) -> None:
        self.capture(self.todo()[0], {"status": 404, "text": ""})
        page1 = self.todo()
        self.assertEqual([t["page"] for t in page1], [1])
        self.capture(page1[0], {"info": {}, "blocked": [], "cards": [card(1, 600), card(2, 400)]})
        page2 = self.todo()
        self.assertEqual([(t["kind"], t.get("page")) for t in page2 if t["kind"] == "list"], [("list", 2)])
        # Sorted largest first: a card under the floor on page 2 means page 3 holds nothing we want.
        self.capture(
            [t for t in page2 if t["kind"] == "list"][0],
            {"info": {}, "blocked": [], "cards": [card(3, 260), card(4, 120)]},
        )
        remaining = self.todo()
        self.assertEqual({t["kind"] for t in remaining}, {"detail"})
        self.assertEqual(
            sorted(t["url"] for t in remaining),
            ["https://demo.example/tokyo/h1", "https://demo.example/tokyo/h2", "https://demo.example/tokyo/h3"],
        )

    def test_a_block_page_fails_the_search_instead_of_reading_as_no_results(self) -> None:
        self.capture(self.todo()[0], {"status": 404, "text": ""})
        self.capture(self.todo()[0], {"info": {}, "blocked": ["captcha"], "cards": []})
        document = self.plan()
        failed = [t for t in document["tasks"] if t["status"] == planning.FAILED]
        self.assertEqual(len(failed), 1)
        rows = {r["id"]: r for r in planning.coverage(document, self.sources, self.profile)}
        self.assertEqual(rows["demo"]["outcome"], "failed")
        self.assertEqual(rows["byhand"]["outcome"], "manual")

    def test_fetching_every_planned_page_reaches_a_plan_with_nothing_left(self) -> None:
        pages = {1: [card(1, 600), card(2, 400)], 2: [card(3, 260), card(4, 120)]}
        for _ in range(10):
            todo = self.todo()
            if not todo:
                break
            for task in todo:
                if task["kind"] == "robots":
                    self.capture(task, {"status": 404, "text": ""})
                elif task["kind"] == "list":
                    self.capture(task, {"info": {}, "blocked": [], "cards": pages[task["page"]]})
                else:
                    self.capture(task, {"url": task["url"], "h1": "", "pairs": pairs(構造="RC造2階建"), "images": [], "blocks": []})
        self.assertEqual(self.todo(), [])
        self.assertNotIn(planning.WAITING, self.plan()["counts"])


class RememberingEarlierRuns(unittest.TestCase):
    def prop(self, price: int) -> dict:
        record = listing(所在地="東京都港区南麻布3", 土地面積="300m2", 建物面積="400m2", 構造="RC造", 価格="%d円" % price)
        merged = dedupe.merge([record])
        merged["status"] = criteria.MATCH
        return merged

    def test_a_second_run_reports_price_cuts_and_delistings(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        first = state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        self.assertEqual(first[0]["change"], "new")
        second = state_store.apply_run(state, "2026-12-02", "2026-12-02", [self.prop(450_000_000)], ["a"])
        self.assertEqual((second[0]["change"], second[0]["previous_price_jpy"]), ("price_down", 500_000_000))
        self.assertEqual(second[0]["id"], first[0]["id"])
        state_store.apply_run(state, "2026-12-09", "2026-12-09", [], ["a"])
        self.assertEqual([g["id"] for g in state_store.gone(state, "2026-12-09")], [first[0]["id"]])

    def test_a_property_is_not_called_delisted_when_its_source_was_not_searched(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        state_store.apply_run(state, "2026-12-02", "2026-12-02", [], [])
        self.assertEqual(state_store.gone(state, "2026-12-02"), [])

    def test_state_survives_a_round_trip_through_json(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        self.assertEqual(json.loads(json.dumps(state, ensure_ascii=False)), state)


if __name__ == "__main__":
    unittest.main()
