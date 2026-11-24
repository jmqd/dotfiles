"""Behaviour of the property search tools, driven through their public functions.

Run: python3 -m unittest discover -s <skill>/tests
"""

from __future__ import annotations

import contextlib
import csv
import datetime
import io
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "jpsearch"))

import cli  # noqa: E402
import criteria  # noqa: E402
import dedupe  # noqa: E402
import listings  # noqa: E402
import pipeline  # noqa: E402
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
            "6億9,000万円": 690_000_000,
            "３億９８００万円": 398_000_000,
            "1億円": 100_000_000,
            "9,800万円": 98_000_000,
            "20,000万円": 200_000_000,
            "2.5億円": 250_000_000,
            "1億2千万円": 120_000_000,
            "1億2345万6000円": 123_456_000,
            "¥488,000,000": 488_000_000,
            "488,000,000円": 488_000_000,
            "488 million yen": 488_000_000,
            "¥680M": 680_000_000,
            "JPY 1.2 billion": 1_200_000_000,
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
            "1987[S62]年08月": (1987, 8),
            "1995/10": (1995, 10),
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

    def test_a_chome_written_in_kanji_reads_as_its_number(self) -> None:
        written = {"一丁目": "1", "十丁目": "10", "十二丁目5": "12", "二十丁目": "20", "二十一丁目3-4": "21", "三田二丁目": "三田2"}
        self.assertEqual({town: text.town_key(town) for town in written}, written)

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

    def test_a_number_before_a_price_does_not_take_its_first_digit(self) -> None:
        # A photo count on the line above once swallowed the 6 of 6億.
        self.assertEqual(text.yen_amounts("画像2枚\n6億9,000万円\n株式会社"), [690_000_000])

    def test_a_distance_in_metres_is_not_a_price_in_millions(self) -> None:
        self.assertEqual(text.yen_amounts("海まで約300m)の保養所です。\n蓼科 2,100万円"), [21_000_000])

    def test_an_unlabelled_card_gives_the_asking_price_not_a_fee(self) -> None:
        card = "月々8.5万円\n那須 20,000万円 4,446.36m2 1368.08m2 12R 管理費 17,938円 1995/10"
        record = listings.normalise("a", "used_house", "u", "", [], card, None, "2026-11-25")
        self.assertEqual(record["price_jpy"], 200_000_000)

    def test_a_card_without_labels_gives_areas_and_address(self) -> None:
        card = "足立区足立4丁目\n東武伊勢崎線 「五反野」駅 徒歩9分 他\n東京都足立区足立4丁目\n1992年9月（築35年）\n土地 279.61m2 / 建物 1387.06m2\n画像2枚\n6億9,000万円"
        record = listings.normalise("a", "used_house", "u", "足立区足立4丁目", [], card, None, "2026-11-25")
        self.assertEqual((record["land_m2"], record["building_m2"], record["price_jpy"]), (279.61, 1387.06, 690_000_000))
        self.assertEqual((record["prefecture"], record["municipality"], record["built_year"]), ("東京都", "足立区", 1992))

    def test_the_search_prefecture_completes_a_card_that_names_only_the_ward(self) -> None:
        record = listings.normalise(
            "a", "used_house", "u", "【中古一戸建】 世田谷区中町４丁目 周辺地図", pairs(価格="5億1,000万円"), "", None, "2026-11-25",
            prefecture_hint="東京都",
        )
        self.assertEqual((record["prefecture"], record["municipality"], record["address"]), ("東京都", "世田谷区", "東京都世田谷区中町4丁目"))

    def test_without_a_search_prefecture_a_bare_town_is_not_guessed(self) -> None:
        record = listings.normalise("a", "used_house", "u", "中町４丁目の邸宅", pairs(価格="5億円"), "世田谷区中町４丁目", None, "2026-11-25")
        self.assertIsNone(record["prefecture"])

    def test_a_railway_run_by_the_prefecture_is_not_an_address(self) -> None:
        card = "東京都大江戸線 「牛込柳町」駅 徒歩5分\n新宿区矢来町\n5億9,800万円"
        record = listings.normalise("a", "used_house", "u", "", [], card, None, "2026-11-25", prefecture_hint="東京都")
        self.assertEqual((record["municipality"], record["address"]), ("新宿区", "東京都新宿区矢来町"))

    def test_a_map_link_caption_is_not_part_of_the_address(self) -> None:
        self.assertEqual(listing(所在地="東京都世田谷区中町4丁目MAP")["address"], "東京都世田谷区中町4丁目")

    def test_a_label_with_a_parenthetical_inside_is_recognised(self) -> None:
        record = listing(**{"建物（専有）面積": "267.5㎡", "管理費等（月額換算）": "48,914円"})
        self.assertEqual((record["building_m2"], record["management_fee"]), (267.5, "48,914円"))

    def test_a_basement_does_not_hide_the_storeys_above_it(self) -> None:
        cases = {"RC2階地下1階建": (2, 1), "地下1階付3階建": (3, 1), "SRC5階地下2階建": (5, 2), "木造2階建": (2, None)}
        for written, expected in cases.items():
            with self.subTest(written):
                s = text.parse_structure(written)
                self.assertEqual((s.floors, s.basement), expected)

    def test_wood_listed_beside_concrete_is_a_mixed_structure(self) -> None:
        for written in ("木・鉄筋コンクリート3階建", "鉄筋コンクリート・木2階建", "木造2階地下1階建一部RC"):
            with self.subTest(written):
                s = text.parse_structure(written)
                self.assertEqual((s.kind, set(s.parts)), (text.MIXED, {text.RC, text.WOOD}))

    def test_a_menu_entry_named_like_a_field_does_not_fill_it(self) -> None:
        record = listings.normalise(
            "a", "used_house", "u", "",
            [{"label": "リフォーム", "value": "売却"}, {"label": "リフォーム", "value": "2023年6月完了 水回り設備交換"}, {"label": "用途地域", "value": "１種中高"}],
            None, None, "2026-11-25",
        )
        self.assertEqual((record["renovation"], record["zoning"]), ("2023年6月完了 水回り設備交換", "1種中高"))

    def test_services_stated_inside_a_remarks_field_are_read(self) -> None:
        record = listing(**{"その他概要・特記事項": "担当者：武田、設備：公営水道、集中浄化槽、プロパンガス", "諸費用": "温泉：温泉使用料9000円／月"})
        self.assertEqual((record["water"], record["sewer"], record["gas"]), ("公営水道", "集中浄化槽", "プロパンガス"))
        self.assertIn("9000円", record["hot_spring"])

    def test_a_town_named_for_its_hot_spring_is_not_a_hot_spring_supply(self) -> None:
        self.assertIsNone(listing(備考="石和温泉駅まで車10分")["hot_spring"])

    def test_listing_remarks_raise_the_flags_a_buyer_must_see(self) -> None:
        cases = {
            "urbanisation_control": listing(用途地域="市街化調整区域"),
            "tenant_occupied": listing(備考="１世帯月額70万円で賃貸中"),
            "leasehold": listing(土地権利="借地権（旧法）"),
            "pre_1981_seismic_code": listing(築年月="1979年3月"),
        }
        for flag, record in cases.items():
            with self.subTest(flag):
                self.assertIn(flag, record["flags"])
        self.assertNotIn("leasehold", listing(土地権利="所有権", 備考="隣地は借地")["flags"])

    def test_a_listing_that_is_not_a_house_to_live_in_is_flagged(self) -> None:
        for title in ("伊豆市熊坂中古保養所", "倉庫、物置用", "伊豆高原の「ペンション ノエル」です", "下北沢の社員寮"):
            with self.subTest(title):
                self.assertIn("not_a_dwelling", listing(title=title)["flags"])
        self.assertIn("not_a_dwelling", listing(物件種目="一棟売りマンション")["flags"])

    def test_a_house_whose_sales_copy_mentions_another_use_is_not_flagged(self) -> None:
        titles = ("ビルトインガレージ付きの邸宅", "二世帯や事務所利用にもご検討いただけます", "家具付売別荘。企業の保養所などにおすすめ", "倉庫付住宅", "8LDK+事務所")
        for title in titles:
            with self.subTest(title):
                self.assertNotIn("not_a_dwelling", listing(title=title, 間取り="5LDK", 建物面積="300m2")["flags"])

    def test_a_structure_stated_in_the_storeys_field_is_read(self) -> None:
        record = listing(**{"構造・工法": "-", "建物階": "木造瓦葺2階建て"})
        self.assertEqual((record["structure"], record["floors"]), (text.WOOD, 2))

    def test_a_no_photo_placeholder_is_not_kept_as_the_listing_s_picture(self) -> None:
        card = listings.normalise("a", "used_house", "u", "", pairs(価格="1億円"), "", "https://img.example/gazo/No_Photo_132_99.jpg", "2026-11-25")
        self.assertIsNone(card["image"])
        page = dict(listing(価格="1億円"), image="https://img.example/gazo/20645338_0001.jpg")
        self.assertEqual(listings.merge_detail(card, page)["image"], "https://img.example/gazo/20645338_0001.jpg")

    def test_a_whole_block_named_only_on_the_listing_page_is_not_a_house(self) -> None:
        card = listing(価格="2億9,800万円", 所在地="東京都新宿区下落合4丁目", 土地面積="234.87m2", 建物面積="439.66m2")
        merged = listings.merge_detail(card, listing(物件種目="一棟売りマンション", 構造="鉄筋コンクリート"))
        self.assertEqual(merged["listing_type"], "building")
        self.assertEqual(criteria.judge(PROFILE, merged).status, criteria.REJECTED)

    def test_a_site_type_label_naming_a_block_is_not_a_house(self) -> None:
        record = listings.normalise("a", "used_house", "u", "", [], "一棟マンション\n荒川区東日暮里３丁目\n189,000万円", None, "2026-11-25", prefecture_hint="東京都")
        self.assertEqual(record["listing_type"], "building")
        self.assertEqual(criteria.judge(PROFILE, record).status, criteria.REJECTED)

    def test_an_outbuilding_in_another_material_does_not_make_the_house_mixed(self) -> None:
        s = text.parse_structure("鉄筋コンクリート造ステンレス鋼板葺地下1階付3階建 ●別棟:軽量鉄骨造亜鉛メッキ鋼板葺平家建 ●別棟2:木造スレート葺平家建")
        self.assertEqual((s.kind, s.floors, s.basement), (text.RC, 3, 1))
        truly_mixed = text.parse_structure("鉄筋コンクリート・鉄骨造銅板葺地下1階付2階建 ●別棟:鉄筋コンクリート造銅板葺平家建")
        self.assertEqual(truly_mixed.kind, text.MIXED)

    def test_a_bare_area_label_beside_a_floor_area_is_the_lot(self) -> None:
        both = listing(面積="（公簿）903.85ｍ2（273.41坪）", 延床面積="（公簿）422.86ｍ2")
        self.assertEqual((both["land_m2"], both["building_m2"]), (903.85, 422.86))
        self.assertIsNone(listing(面積="903.85ｍ2")["land_m2"])

    def test_a_title_is_the_property_name_without_badges_or_link_captions(self) -> None:
        cases = {
            "中野区本町2丁目\n人気物件TOP10入り": "中野区本町2丁目",
            "【中古一戸建】 文京区千駄木3丁目 周辺地図": "文京区千駄木3丁目",
            "MAP": "",
            "【大和ハウス工業 軽量鉄骨造】成城の邸宅": "【大和ハウス工業 軽量鉄骨造】成城の邸宅",
        }
        for written, expected in cases.items():
            with self.subTest(written):
                self.assertEqual(listing(title=written)["title"], expected)

    def test_an_address_is_shown_one_way_whatever_the_site_puts_around_it(self) -> None:
        cases = ("東京都杉並区西荻南4丁目 GoogleMaps", "自治体情報 東京都 杉並区 西荻南 4丁目", "東京都杉並区西荻南４丁目 地図を見る")
        for written in cases:
            with self.subTest(written):
                record = listing(所在地=written)
                self.assertEqual((record["address"], record["municipality"], record["town"]), ("東京都杉並区西荻南4丁目", "杉並区", "西荻南4"))

    def test_the_detail_page_address_replaces_a_place_guessed_from_a_card_title(self) -> None:
        card = listings.normalise(
            "a", "used_house", "u", "渋谷区代々木五丁目賃貸併用住宅", [], "中古戸建\n69,800万円", None, "2026-11-25", prefecture_hint="東京都"
        )
        self.assertTrue(card["address_guessed"])
        merged = listings.merge_detail(card, listing(所在地="東京都渋谷区代々木5丁目"))
        self.assertEqual((merged["address"], merged["town"]), ("東京都渋谷区代々木5丁目", "代々木5"))
        stated = listings.merge_detail(listing(所在地="東京都渋谷区代々木5丁目"), listing(所在地="東京都渋谷区代々木五丁目12-3"))
        self.assertEqual(stated["address"], "東京都渋谷区代々木5丁目")


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

    def test_two_accepted_materials_together_are_a_pass(self) -> None:
        self.assertEqual(self.status(self.house("東京都港区南麻布3", "200m2", structure="SRC造地下1階付5階建一部RC")), criteria.MATCH)

    def test_a_structure_stated_only_as_other_is_unverified(self) -> None:
        verdict = criteria.judge(PROFILE, self.house("東京都港区南麻布3", "200m2", structure="その他構造2階地下1階建"))
        self.assertEqual(verdict.status, criteria.UNVERIFIED)
        self.assertIn("other", verdict.reasons(criteria.UNKNOWN)[0])

    def test_a_tenant_or_a_non_residential_use_sends_a_match_to_review(self) -> None:
        tenanted = dict(self.house("東京都港区南麻布3", "200m2"), flags=["tenant_occupied"])
        verdict = criteria.judge(PROFILE, tenanted)
        self.assertEqual(verdict.status, criteria.NEAR_MISS)
        self.assertIn("tenant", verdict.reasons(criteria.NEAR)[0])
        warehouse = dict(self.house("東京都港区南麻布3", "200m2"), flags=["not_a_dwelling"])
        self.assertEqual(criteria.judge(PROFILE, warehouse).status, criteria.NEAR_MISS)

    def test_the_profile_decides_which_flags_reject_or_pass(self) -> None:
        base = {"building_m2_min": 250, "structures": ["RC"], "zones": [{"id": "all", "land_m2_min": 190}]}
        leasehold = dict(self.house("東京都港区南麻布3", "200m2"), flags=["leasehold", "tenant_occupied"])
        strict = criteria.parse_profile(dict(base, reject_flags=["leasehold"]))
        relaxed = criteria.parse_profile(dict(base, review_flags=[]))
        self.assertEqual(criteria.judge(strict, leasehold).status, criteria.REJECTED)
        self.assertEqual(criteria.judge(relaxed, leasehold).status, criteria.MATCH)
        with self.assertRaises(criteria.ProfileError):
            criteria.parse_profile(dict(base, reject_flags=["haunted"]))

    def test_a_house_outside_the_profile_s_areas_is_rejected_wherever_it_was_found(self) -> None:
        zones = [{"id": "all", "land_m2_min": 1000}]
        profile = criteria.parse_profile({"building_m2_min": 250, "structures": ["RC"], "zones": zones, "areas": ["東京都", "Nagano"]})
        nasu = self.house("栃木県那須郡那須町高久丙", "1,007.75m2")
        verdict = criteria.judge(profile, nasu)
        self.assertEqual(verdict.status, criteria.REJECTED)
        self.assertIn("栃木県", verdict.reasons(criteria.FAIL)[0])
        self.assertEqual(criteria.judge(profile, self.house("長野県茅野市北山", "2,236.59m2")).status, criteria.MATCH)
        # An address that names no prefecture is not ruled out on a guess.
        self.assertEqual(criteria.judge(profile, self.house("", "2,236.59m2")).status, criteria.UNVERIFIED)


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

    def judged(self, records: list) -> list:
        return [(j.verdict.status, j.prop) for j in pipeline.judged_properties(PROFILE, records)]

    def test_what_one_agent_states_settles_it_for_every_listing_of_the_house(self) -> None:
        base = {"所在地": "東京都世田谷区成城6", "土地面積": "330.00m2", "建物面積": "260.00m2", "築年月": "2006年6月", "販売価格": "3億円"}
        silent = listing("https://x/1", **base)
        wooden = listing("https://x/2", **dict(base, 構造="軽量鉄骨2階建"))
        [(status, prop)] = self.judged([silent, wooden])
        self.assertEqual((status, prop["structure"], len(prop["urls"])), (criteria.REJECTED, text.STEEL, 2))

    def test_a_tenant_one_agent_mentions_shows_on_the_property(self) -> None:
        base = {"所在地": "東京都新宿区矢来町", "土地面積": "246.94m2", "建物面積": "489.53m2", "築年月": "1996年3月", "販売価格": "5億9800万円", "構造": "SRC造"}
        [(status, prop)] = self.judged([listing("https://x/1", **base), listing("https://x/2", **dict(base, 備考="１世帯賃貸中"))])
        self.assertEqual(status, criteria.NEAR_MISS)
        self.assertIn("tenant_occupied", prop["flags"])

    def test_one_room_of_house_size_is_held_for_review_unless_another_agent_describes_rooms(self) -> None:
        base = {"所在地": "東京都大田区北千束2", "土地面積": "234.08m2", "建物面積": "316.87m2", "築年月": "2009年3月", "販売価格": "4億5800万円", "構造": "RC造"}
        one_room = listing("https://x/1", **dict(base, 間取り="ワンルーム"))
        [(status, prop)] = self.judged([one_room])
        self.assertEqual((status, prop["flags"]), (criteria.NEAR_MISS, ["not_a_dwelling"]))
        # Another agent lists the rooms of the same house: the one room was a slip of the first, not a hall.
        [(status, prop)] = self.judged([one_room, listing("https://x/2", **dict(base, 間取り="4LLDDKK+3S(納戸)"))])
        self.assertEqual((status, prop["flags"]), (criteria.MATCH, []))

    def test_listings_that_disagree_on_the_structure_go_to_review_with_both_statements(self) -> None:
        base = {"所在地": "東京都世田谷区成城6", "土地面積": "330.00m2", "建物面積": "260.00m2", "築年月": "2006年6月", "販売価格": "3億円"}
        records = [listing("https://x/1", **dict(base, 構造="RC造2階建")), listing("https://x/2", **dict(base, 構造="鉄骨2階地下1階建"))]
        [(status, prop)] = self.judged(records)
        self.assertEqual(status, criteria.NEAR_MISS)
        self.assertEqual({v["text"] for v in prop["structure_variants"]}, {"RC造2階建", "鉄骨2階地下1階建"})

    def test_listings_that_agree_on_rc_and_src_are_still_a_match(self) -> None:
        base = {"所在地": "東京都世田谷区成城6", "土地面積": "330.00m2", "建物面積": "260.00m2", "築年月": "2006年6月", "販売価格": "3億円"}
        [(status, _prop)] = self.judged([listing("https://x/1", **dict(base, 構造="RC造")), listing("https://x/2", **dict(base, 構造="SRC造"))])
        self.assertEqual(status, criteria.MATCH)

    def test_one_lot_at_one_price_in_one_town_is_one_house_even_when_agents_disagree_on_the_rest(self) -> None:
        base = {"所在地": "東京都大田区中馬込1丁目", "土地面積": "182.18m2", "販売価格": "1億7480万円", "構造": "RC造3階建"}
        records = [
            listing("https://x/1", **dict(base, 建物面積="277.86m2", 築年月="1989年9月")),
            listing("https://x/2", **dict(base, 建物面積="266.07m2", 築年月="1995年3月")),
            listing("https://x/3", **dict(base, 建物面積="266.07m2", 築年月="1989年8月")),
        ]
        [(_status, prop)] = self.judged(records)
        self.assertEqual((prop["building_m2"], prop["building_m2_variants"], prop["built_year"]), (266.07, [266.07, 277.86], 1989))
        elsewhere = listing("https://x/4", **dict(base, 所在地="東京都大田区中馬込2丁目", 建物面積="300m2", 築年月="2001年1月"))
        self.assertEqual(len(dedupe.cluster(records + [elsewhere])), 2)


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

    def test_brackets_match_whether_or_not_they_are_percent_encoded(self) -> None:
        rules = "User-agent: *\nDisallow: /search/*?*[*]=\nDisallow: /list?kind%5B%5D=9"
        self.assertFalse(robots.allowed(rules, "https://s.jp/search/13/?geo%5B%5D=13101"))
        self.assertFalse(robots.allowed(rules, "https://s.jp/search/13/?geo[]=13101"))
        self.assertFalse(robots.allowed(rules, "https://s.jp/list?kind[]=9"))
        self.assertTrue(robots.allowed(rules, "https://s.jp/search/13/?geo=13101"))

    def test_a_site_that_shuts_out_the_assistant_shuts_out_this_toolkit(self) -> None:
        closed = "User-agent: *\nAllow: /\n\nUser-agent: GPTBot\nUser-agent: ClaudeBot\nDisallow: /"
        other_bots_only = "User-agent: *\nAllow: /\n\nUser-agent: GPTBot\nDisallow: /"
        partly = "User-agent: *\nAllow: /\n\nUser-agent: Claude-User\nDisallow: /search/"
        self.assertFalse(robots.allowed(closed, "https://s.jp/house/1"))
        self.assertTrue(robots.allowed(other_bots_only, "https://s.jp/house/1"))
        self.assertFalse(robots.allowed(partly, "https://s.jp/search/?a=1"))
        self.assertTrue(robots.allowed(partly, "https://s.jp/house/1"))


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


def tokyo_profile(**changes: object) -> criteria.Profile:
    data = {
        "building_m2_min": 250, "structures": ["RC", "SRC"], "areas": ["東京都"],
        "zones": [
            {"id": "tokyo-23", "prefecture": "東京都", "municipality_suffix": "区", "land_m2_min": 190},
            {"id": "elsewhere", "land_m2_min": 1000},
        ],
    }
    data.update(changes)
    return criteria.parse_profile(data)


class PlanFixture(unittest.TestCase):
    """A workspace in a temporary directory, planned against `registry_data`, with captures written by hand."""

    registry_data: dict = {"sources": []}

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ws = Workspace(Path(self.tmp.name), "2026-11-25")
        self.profile = tokyo_profile()
        self.sources = registry.parse_registry(self.registry_data)

    def plan(self, retry_failed: bool = False) -> dict:
        state = state_store.load(self.ws)
        return planning.Planner(self.ws, self.profile, self.sources, state, retry_failed=retry_failed).build()

    def todo(self) -> list:
        return [t for t in self.plan()["tasks"] if t["status"] == planning.TODO]

    def lists(self, tasks: list) -> list:
        return [t for t in tasks if t["kind"] == "list"]

    def capture(self, task: dict, result: dict, error: str = None, http_status: int = 200) -> None:
        envelope = {
            "task": task, "attempt": task.get("attempt", 1), "fetched_at": "t", "http_status": http_status, "error": error, "result": result,
        }
        write_json(self.ws.home / task["out"], envelope)

    def allow_everything(self) -> None:
        self.capture(self.todo()[0], {"status": 404, "text": ""})

    def results(self, task: dict, cards: list) -> None:
        self.capture(task, {"info": {}, "blocked": [], "cards": cards})


class PlanningARun(PlanFixture):
    registry_data = REGISTRY

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

    def test_a_page_read_for_a_search_that_has_since_changed_is_read_again(self) -> None:
        self.allow_everything()
        first = self.todo()[0]
        self.results(first, [card(1, 600)])
        self.assertEqual(self.lists(self.todo()), [])
        # A wider near-miss band lowers the land filter, so the same page file now stands for another URL.
        self.profile = tokyo_profile(near_miss_percent=20)
        [again] = self.lists(self.todo())
        self.assertNotEqual(again["url"], first["url"])
        self.assertEqual((again["out"], again["why"]), (first["out"], "the search changed since this page was read"))

    def test_paging_stops_below_the_size_threshold_and_details_follow(self) -> None:
        self.allow_everything()
        page1 = self.todo()
        self.assertEqual([t["page"] for t in page1], [1])
        self.results(page1[0], [card(1, 600), card(2, 400)])
        page2 = self.lists(self.todo())
        self.assertEqual([t["page"] for t in page2], [2])
        # Sorted largest first: once the list has run below the floor, page 3 holds nothing we want.
        self.results(page2[0], [card(3, 260), card(4, 120), card(5, 110)])
        remaining = self.todo()
        self.assertEqual({t["kind"] for t in remaining}, {"detail"})
        self.assertEqual(
            sorted(t["url"] for t in remaining),
            ["https://demo.example/tokyo/h1", "https://demo.example/tokyo/h2", "https://demo.example/tokyo/h3"],
        )

    def test_a_promoted_card_out_of_the_sort_order_does_not_end_the_search(self) -> None:
        self.allow_everything()
        self.results(self.todo()[0], [card(1, 600), card(9, 80, title="PR"), card(2, 400)])
        self.assertEqual([t["page"] for t in self.lists(self.todo())], [2])

    def test_a_site_that_serves_its_last_page_again_ends_the_search(self) -> None:
        self.allow_everything()
        self.results(self.todo()[0], [card(1, 600), card(2, 400)])
        self.results(self.lists(self.todo())[0], [card(1, 600), card(2, 400)])
        self.assertEqual(self.lists(self.todo()), [])

    def test_a_page_that_failed_to_load_is_fetched_once_more_then_given_up(self) -> None:
        self.allow_everything()
        first = self.todo()[0]
        self.capture(first, None, error="page load took longer than 90 s")
        again = self.todo()
        self.assertEqual([(t["id"], t["attempt"]) for t in again], [(first["id"], 2)])
        self.capture(again[0], None, error="page load took longer than 90 s")
        self.assertEqual(self.todo(), [])
        self.assertEqual([t["status"] for t in self.lists(self.plan()["tasks"])], [planning.FAILED])
        retried = [t for t in self.plan(retry_failed=True)["tasks"] if t["status"] == planning.TODO]
        self.assertEqual([(t["id"], t["attempt"]) for t in retried], [(first["id"], 3)])

    def test_a_robots_txt_that_failed_to_load_is_fetched_again_before_the_host_is_closed(self) -> None:
        robots_task = self.todo()[0]
        self.capture(robots_task, None, error="net::ERR_CONNECTION_RESET")
        self.assertEqual([(t["kind"], t["attempt"]) for t in self.todo()], [("robots", 2)])
        self.capture(self.todo()[0], None, error="net::ERR_CONNECTION_RESET")
        self.assertEqual(self.todo(), [])
        self.assertEqual([t["status"] for t in self.lists(self.plan()["tasks"])], [planning.DISALLOWED])

    def test_a_withdrawn_listing_page_is_reported_as_gone_not_as_unreadable(self) -> None:
        self.allow_everything()
        self.results(self.todo()[0], [card(1, 600)])
        detail = [t for t in self.todo() if t["kind"] == "detail"][0]
        self.capture(detail, {"url": detail["url"], "title": "エラー｜SUUMO(スーモ)", "h1": "", "pairs": [], "images": [], "blocks": []})
        document = self.plan()
        self.assertEqual([t["status"] for t in document["tasks"] if t["kind"] == "detail"], [planning.GONE])
        row = planning.coverage(document, self.sources, self.profile)[0]
        self.assertEqual((row["details_gone"], row["details_failed"]), (1, 0))

    def test_a_block_page_fails_the_search_instead_of_reading_as_no_results(self) -> None:
        self.capture(self.todo()[0], {"status": 404, "text": ""})
        self.capture(self.todo()[0], {"info": {}, "blocked": ["captcha"], "cards": []})
        document = self.plan()
        failed = [t for t in document["tasks"] if t["status"] == planning.FAILED]
        self.assertEqual(len(failed), 1)
        rows = {r["id"]: r for r in planning.coverage(document, self.sources, self.profile)}
        self.assertEqual(rows["demo"]["outcome"], "failed")
        self.assertEqual(rows["byhand"]["outcome"], "manual")

    def test_an_error_page_fails_the_search_instead_of_reading_as_no_results(self) -> None:
        self.allow_everything()
        self.capture(self.todo()[0], {"info": {"title": "502 Bad Gateway"}, "blocked": [], "cards": []})
        [task] = self.lists(self.plan()["tasks"])
        self.assertEqual(task["status"], planning.FAILED)
        self.assertIn("502 Bad Gateway", task["why"])

    def test_a_search_url_the_site_no_longer_knows_is_a_failure_and_a_missing_listing_is_gone(self) -> None:
        self.allow_everything()
        first = self.todo()[0]
        self.capture(first, {"info": {"title": "ページが見つかりません"}, "blocked": [], "cards": []}, http_status=404)
        self.assertEqual([t["status"] for t in self.lists(self.plan()["tasks"])], [planning.FAILED])
        self.results(first, [card(1, 600)])
        detail = [t for t in self.todo() if t["kind"] == "detail"][0]
        self.capture(detail, {"url": detail["url"], "title": "お探しのページ", "h1": "", "pairs": pairs(価格="1億円"), "images": [], "blocks": []}, http_status=404)
        self.assertEqual([t["status"] for t in self.plan()["tasks"] if t["kind"] == "detail"], [planning.GONE])


class PlanningASiteWhoseHitCountIsTrusted(PlanFixture):
    registry_data = {
        "sources": [
            {
                "id": "counted", "name": "Counted", "kind": "portal", "home": "https://demo.example/",
                "searches": [
                    {
                        "listing_type": "used_house", "scope": "prefecture", "url": "https://demo.example/{pref}/houses?p={page}",
                        "per_page": 10, "hints": {"hits": ".count"},
                    }
                ],
            }
        ]
    }

    def page_of(self, task: dict, count: int) -> None:
        self.capture(task, {"info": {"hits": "25件"}, "blocked": [], "cards": [card(n, 300) for n in range(1, count + 1)]})

    def test_a_page_cut_short_while_loading_is_fetched_once_more_then_reported(self) -> None:
        self.allow_everything()
        first = self.todo()[0]
        self.page_of(first, 3)
        again = self.lists(self.todo())
        self.assertEqual([(t["id"], t["attempt"]) for t in again], [(first["id"], 2)])
        self.page_of(again[0], 3)
        [task] = self.lists(self.plan()["tasks"])
        self.assertEqual((task["status"], task["why"]), (planning.FAILED, "page is incomplete: 3 of 10 cards arrived"))

    def test_a_full_page_is_read_and_the_next_one_planned(self) -> None:
        self.allow_everything()
        self.page_of(self.todo()[0], 10)
        self.assertEqual([t["page"] for t in self.lists(self.todo())], [2])


class PlanningTheWholeRun(PlanFixture):
    registry_data = REGISTRY

    def test_fetching_every_planned_page_reaches_a_plan_with_nothing_left(self) -> None:
        pages = {1: [card(1, 600), card(2, 400)], 2: [card(3, 260), card(4, 120)], 3: [card(5, 110), card(6, 100)]}
        for _ in range(10):
            todo = self.todo()
            if not todo:
                break
            for task in todo:
                if task["kind"] == "robots":
                    self.capture(task, {"status": 404, "text": ""})
                elif task["kind"] == "list":
                    self.results(task, pages[task["page"]])
                else:
                    self.capture(task, {"url": task["url"], "h1": "", "pairs": pairs(構造="RC造2階建"), "images": [], "blocks": []})
        self.assertEqual(self.todo(), [])
        self.assertNotIn(planning.WAITING, self.plan()["counts"])


class PlanningSitesThatNameTheirMunicipalities(PlanFixture):
    registry_data = {
        "sources": [
            {
                "id": "byform", "name": "By form", "kind": "aggregator", "home": "https://form.example/",
                "searches": [
                    {
                        "listing_type": "used_house", "scope": "prefecture", "pref_format": "code",
                        "url": "https://form.example/{pref}/list?{cities}&b={building_min}&l={land_min}&p={page}",
                        "cities_param": "m_adr%5B%5D", "cities_per_url": 2,
                        "building_min": "free", "land_min": {"free_up_to": 150}, "per_page": 100,
                        "discover": {"url": "https://form.example/{pref}/area", "inputs": "input[name='m_adr[]']"},
                    }
                ],
            },
            {
                "id": "bypath", "name": "By path", "kind": "broker", "home": "https://path.example/",
                "searches": [
                    {
                        "listing_type": "used_house", "scope": "prefecture", "pref_format": "code",
                        "url": "https://path.example/pref/{pref}/city/{city}/?cityCode={cities}&p={page}",
                        "discover": {"url": "https://path.example/pref/{pref}/city/", "link": "/pref/\\d+/city/(\\d{5})/"},
                    }
                ],
            },
        ]
    }

    def test_nothing_is_fetched_before_robots_txt(self) -> None:
        self.assertEqual({(t["kind"], t["status"]) for t in self.plan()["tasks"]}, {("robots", "todo"), ("discover", "waiting")})

    def test_municipality_codes_read_from_a_form_fill_the_search_url(self) -> None:
        for task in self.todo():
            self.capture(task, {"status": 404, "text": ""})
        discover = {t["source"]: t for t in self.todo()}
        self.assertEqual(discover["byform"]["extract"], {"fn": "inputs", "selector": "input[name='m_adr[]']"})
        boxes = [("13101", "千代田区 (12)"), ("13102", "中央区 (0)"), ("13103", "港区"), ("13104", "新宿区 (3)"), ("on", "すべて")]
        self.capture(discover["byform"], {"blocked": [], "inputs": [{"value": v, "text": t} for v, t in boxes]})
        links = [("13101", "千代田区"), ("13102", "中央区"), ("13103", "港区")]
        self.capture(discover["bypath"], {"blocked": [], "links": [{"href": "https://path.example/pref/13/city/%s/" % c, "text": n} for c, n in links]})
        urls = sorted(t["url"] for t in self.todo())
        self.assertEqual(
            urls,
            [
                # A ward with no listings is left out, the "all" box is not a code, and long lists are split.
                # The land filter takes any value up to 150, so the Tokyo floor of 171 is sent as 150.
                "https://form.example/13/list?m_adr%5B%5D=13101&m_adr%5B%5D=13103&b=225&l=150&p=1",
                "https://form.example/13/list?m_adr%5B%5D=13104&b=225&l=150&p=1",
                # A site that wants one municipality in its path takes the first there and the rest as a list.
                "https://path.example/pref/13/city/13101/?cityCode=13102,13103&p=1",
            ],
        )


class PlanningASearchThatOnlyReturnsLargeBuildings(PlanFixture):
    registry_data = {
        "sources": [
            {
                "id": "bins", "name": "Bins", "kind": "resort", "home": "https://bins.example/",
                "searches": [
                    {"listing_type": "used_house", "scope": "nationwide", "url": "https://bins.example/list?big=200&p={page}", "fixed_building_min": 200}
                ],
            }
        ]
    }

    def test_it_runs_when_the_profile_wants_nothing_smaller(self) -> None:
        self.allow_everything()
        self.assertEqual([t["url"] for t in self.todo()], ["https://bins.example/list?big=200&p=1"])

    def test_it_is_skipped_and_reported_when_it_would_hide_smaller_houses(self) -> None:
        self.profile = tokyo_profile(building_m2_min=150)
        document = self.plan()
        self.assertEqual(self.todo(), [])
        row = planning.coverage(document, self.sources, self.profile)[0]
        self.assertEqual(row["outcome"], "not applicable")
        self.assertIn("200 m²", row["problems"][0])


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

    def test_a_house_still_listed_but_now_rejected_is_ruled_out_not_delisted(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        [first] = state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        still_there = {first["urls"][0]: "structure is wood"}
        for _build in range(2):
            state_store.apply_run(state, "2026-12-02", "2026-12-02", [], ["a"], still_there)
            self.assertEqual(state_store.gone(state, "2026-12-02"), [])
            self.assertEqual([(d["id"], d["reason"]) for d in state_store.dropped(state, "2026-12-02")], [(first["id"], "structure is wood")])
        # It is reported in the run that found it, not in every run after.
        state_store.apply_run(state, "2026-12-09", "2026-12-09", [], ["a"], still_there)
        self.assertEqual(state_store.dropped(state, "2026-12-09"), [])
        # Once its listing is gone as well, it is delisted.
        state_store.apply_run(state, "2026-12-16", "2026-12-16", [], ["a"], {})
        self.assertEqual([g["id"] for g in state_store.gone(state, "2026-12-16")], [first["id"]])

    def test_state_survives_a_round_trip_through_json(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        self.assertEqual(json.loads(json.dumps(state, ensure_ascii=False)), state)

    def test_building_a_run_twice_reports_the_same_changes_as_building_it_once(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        again = state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        self.assertEqual(again[0]["change"], "new")
        for _ in range(2):
            later = state_store.apply_run(state, "2026-12-02", "2026-12-02", [self.prop(450_000_000)], ["a"])
            self.assertEqual((later[0]["change"], later[0]["previous_price_jpy"]), ("price_down", 500_000_000))
        self.assertEqual(later[0]["prices"], [["2026-11-25", 500_000_000], ["2026-12-02", 450_000_000]])

    def test_a_candidate_that_a_later_build_of_the_same_run_rules_out_leaves_no_trace(self) -> None:
        state = {"version": 1, "properties": {}, "details": {}, "runs": []}
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [self.prop(500_000_000)], ["a"])
        state_store.apply_run(state, "2026-11-25", "2026-11-25", [], ["a"])
        self.assertEqual(state["properties"], {})
        self.assertEqual(state_store.gone(state, "2026-11-25"), [])


class TheShippedRegistryAndProfile(unittest.TestCase):
    def test_every_search_builds_a_url_for_every_prefecture_it_covers(self) -> None:
        sources = registry.load_registry()
        self.assertGreater(sum(1 for s in sources if s.searches), 0)
        for source in sources:
            for search in source.searches:
                for prefecture in search.prefectures or text.PREFECTURES:
                    with self.subTest(source=source.id, prefecture=prefecture):
                        url = search.page_url(prefecture, "13101", 225.0, 171.0, search.page_first, ("13101", "13102"))
                        self.assertRegex(url, r"^https://[^{}\s]+$")

    def test_every_source_a_person_must_browse_says_how(self) -> None:
        for source in registry.load_registry():
            if not source.searches:
                with self.subTest(source=source.id):
                    self.assertTrue(source.manual.strip())

    def test_the_default_profile_is_the_standing_brief(self) -> None:
        profile = criteria.load_profile(cli.DEFAULT_PROFILE)
        self.assertEqual((profile.building_m2_min, profile.structures), (250.0, ("RC", "SRC")))
        self.assertEqual(profile.zone_for("東京都", "杉並区").land_m2_min, 190.0)
        self.assertEqual(profile.zone_for("東京都", "町田市").land_m2_min, 1000.0)
        self.assertEqual(profile.zone_for("長野県", "北佐久郡軽井沢町").land_m2_min, 1000.0)

    def test_a_workspace_entry_replaces_a_shipped_source_and_adds_new_ones(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            overlay = Path(tmp) / "sources.json"
            mine = [
                {"id": "suumo", "name": "SUUMO, by hand", "kind": "portal", "home": "https://suumo.jp/", "manual": "browse it"},
                {"id": "my-agent", "name": "My agent", "kind": "resort", "home": "https://agent.example/", "areas": ["長野県"], "rank": 1},
            ]
            overlay.write_text(json.dumps({"sources": mine}, ensure_ascii=False), encoding="utf-8")
            by_id = {s.id: s for s in registry.load_registry(overlay=overlay)}
        self.assertEqual((by_id["suumo"].name, by_id["suumo"].searches), ("SUUMO, by hand", ()))
        self.assertTrue(by_id["my-agent"].covers(("長野県",)))
        self.assertFalse(by_id["my-agent"].covers(("東京都",)))

    def test_a_registry_entry_the_planner_could_not_use_is_refused(self) -> None:
        base = {"id": "x", "name": "X", "kind": "portal", "home": "https://x.example/"}
        broken = [
            dict(base, kind="blog"),
            dict(base, access="maybe"),
            dict(base, searches=[{"listing_type": "used_house", "scope": "prefecture", "url": "https://x.example/?p={page}"}]),
            dict(base, searches=[{"listing_type": "used_house", "scope": "nationwide", "url": "https://x.example/{region}"}]),
            dict(base, searches=[{"listing_type": "used_house", "scope": "city", "url": "https://x.example/{city}"}]),
        ]
        for entry in broken:
            with self.subTest(entry=entry):
                with self.assertRaises(registry.RegistryError):
                    registry.parse_registry({"sources": [entry]})


class BuildingAReportFromPagesFiledByHand(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.run_cli("init")
        profile = json.loads((self.home / "profile.json").read_text(encoding="utf-8"))
        # No registry source is searched: the test reads no site.
        profile["sources"] = ["agency-x"]
        (self.home / "profile.json").write_text(json.dumps(profile, ensure_ascii=False), encoding="utf-8")

    def run_cli(self, *arguments: str) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(list(arguments) + ["--home", str(self.home), "--run", "2026-11-25"])
        self.assertEqual(code, 0, out.getvalue())
        return out.getvalue()

    def file_results(self) -> None:
        def house(n: int, **fields: str) -> dict:
            base = {"価格": "1億2,000万円", "土地面積": "1,52%d.5㎡" % n, "建物面積": "31%d.2㎡" % n, "築年月": "1990年4月"}
            return {"url": "https://agency.example/house/%d" % n, "title": "", "pairs": pairs(**dict(base, **fields)), "text": "", "image": None}

        page = {
            "info": {"url": "https://agency.example/list"},
            "cards": [
                house(1, 所在地="北佐久郡軽井沢町長倉", 構造="鉄筋コンクリート造2階建"),
                house(2, 所在地="北佐久郡軽井沢町発地", 構造="木造2階建"),
                house(3, 所在地="北佐久郡軽井沢町追分"),
            ],
        }
        path = self.home / "page.json"
        path.write_text(json.dumps(page, ensure_ascii=False), encoding="utf-8")
        self.run_cli("add", "list", str(path), "--source", "agency-x", "--prefecture", "長野県")

    def candidates(self) -> dict:
        data = json.loads((self.home / "search/runs/2026-11-25/candidates.json").read_text(encoding="utf-8"))
        return {p["urls"][0]: p for p in data["properties"]}

    def test_matches_unknowns_and_rejections_land_where_a_reader_looks_for_them(self) -> None:
        self.file_results()
        self.run_cli("build")
        found = self.candidates()
        match = found["https://agency.example/house/1"]
        self.assertEqual((match["status"], match["prefecture"], match["zone"], match["change"]), ("match", "長野県", "elsewhere", "new"))
        unknown = found["https://agency.example/house/3"]
        self.assertEqual(unknown["status"], "unverified")
        self.assertIn("structure not stated", unknown["open_points"][0])
        self.assertNotIn("https://agency.example/house/2", found)
        run = self.home / "search/runs/2026-11-25"
        with (run / "rejected.csv").open(encoding="utf-8-sig", newline="") as handle:
            rejected = {row["url"]: row["reason"] for row in csv.DictReader(handle)}
        self.assertEqual(rejected, {"https://agency.example/house/2": "structure is wood"})
        report = (run / "report.html").read_text(encoding="utf-8")
        self.assertIn("https://agency.example/house/1", report)
        self.assertIn("agency-x", report)

    def test_building_again_after_a_note_keeps_the_property_new_and_shows_the_note(self) -> None:
        self.file_results()
        self.run_cli("build")
        match = self.candidates()["https://agency.example/house/1"]
        self.run_cli("mark", match["id"], "shortlist", "--note", "Karuizawa RC villa")
        self.run_cli("build")
        again = self.candidates()["https://agency.example/house/1"]
        self.assertEqual((again["change"], again["mark"], again["note"]), ("new", "shortlist", "Karuizawa RC villa"))

    def test_the_source_list_can_be_narrowed_to_what_a_person_must_browse(self) -> None:
        listed = self.run_cli("sources", "--mode", "manual", "--area", "長野県")
        self.assertNotIn(" auto ", listed)
        self.assertRegex(listed, r"\d+ sources")
        self.assertIn("How to search it by hand", self.run_cli("sources", "--id", listed.splitlines()[1].split()[0]))


if __name__ == "__main__":
    unittest.main()
