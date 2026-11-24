"""Parse the text Japanese listings use for prices, areas, dates, structure and addresses.

Every parser returns None (or a value whose fields are None) when the text
does not say, so callers can tell "unknown" from "does not qualify".
"""

from __future__ import annotations

import datetime
import re
import unicodedata
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

TSUBO_M2 = 400.0 / 121.0

_KANJI_DIGITS = {"〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}


def nfkc(text: object) -> str:
    """Fold full-width digits, letters and symbols to ASCII (㎡ becomes m2)."""
    if text is None:
        return ""
    folded = unicodedata.normalize("NFKC", str(text))
    return folded.replace("m²", "m2").replace("\u2212", "-").replace("\u2015", "-").replace("\u30fc", "ー")


def squash(text: object) -> str:
    return re.sub(r"\s+", " ", nfkc(text)).strip()


def _num(token: str) -> float:
    return float(token.replace(",", ""))


# ---------------------------------------------------------------- price

_NUM = r"\d[\d,]*(?:\.\d+)?"
# Amounts in 億 and 万. Every alternative needs a unit, so a bare number can
# never start a match and swallow the digits of the amount that follows it.
_KANJI_YEN = re.compile(
    rf"(?P<oku>{_NUM})\s*億(?:\s*(?P<sen>{_NUM})\s*千\s*万|\s*(?P<man>{_NUM})\s*万)?(?P<rest>\d[\d,]*(?=\s*円))?"
    rf"|(?:(?P<sen2>{_NUM})\s*千\s*万|(?P<man2>{_NUM})\s*万)(?P<rest2>\d[\d,]*(?=\s*円))?"
)
_PLAIN_YEN = re.compile(rf"(?:[¥￥]|JPY\s*)(?P<a>\d[\d,]{{5,}})(?!\s*(?:[MBmb]\b|million|billion))|(?P<b>\d[\d,]{{6,}})\s*円")
# "¥680M", "JPY 1.2 billion", "488 million yen": a currency mark is required,
# or "300m" (metres) would read as 300 million.
_WESTERN_YEN = re.compile(
    rf"(?:[¥￥]|JPY\s*)(?P<n>{_NUM})\s*(?P<unit>billion|million|bn|mil|[MB])\b"
    rf"|(?P<n2>{_NUM})\s*(?P<unit2>billion|million)\s*(?:yen|JPY)",
    re.I,
)
_UNDISCLOSED = re.compile(r"応談|応相談|相談|未定|お問い?合わ?せ|非公開|ASK|upon request|negotiable|TBD", re.I)


@dataclass(frozen=True)
class Price:
    """A listing price in yen. `low == high` unless the listing gives a range."""

    low: Optional[int]
    high: Optional[int]
    undisclosed: bool = False


def _kanji_amounts(s: str) -> List[Tuple[int, int, int]]:
    """(start, end, yen) of each 億/万 amount in already-folded text."""
    out = []
    for m in _KANJI_YEN.finditer(s):
        total = 0.0
        if m.group("oku"):
            total += _num(m.group("oku")) * 1e8
        for group, scale in (("sen", 1e7), ("sen2", 1e7), ("man", 1e4), ("man2", 1e4), ("rest", 1.0), ("rest2", 1.0)):
            if m.group(group):
                total += _num(m.group(group)) * scale
        out.append((m.start(), m.end(), int(round(total))))
    return out


def yen_amounts(text: object) -> List[int]:
    """All yen amounts in the text, in order of appearance."""
    s = nfkc(text)
    kanji = _kanji_amounts(s)
    found: List[Tuple[int, int]] = [(start, value) for start, _end, value in kanji]
    for m in _PLAIN_YEN.finditer(s):
        if any(start <= m.start() < end for start, end, _value in kanji):
            continue
        found.append((m.start(), int(round(_num(m.group("a") or m.group("b"))))))
    for m in _WESTERN_YEN.finditer(s):
        unit = (m.group("unit") or m.group("unit2")).lower()
        scale = 1e9 if unit in ("billion", "bn", "b") else 1e6
        found.append((m.start(), int(round(_num(m.group("n") or m.group("n2")) * scale))))
    found.sort()
    return [v for _pos, v in found if v > 0]


def asking_price_in(text: object) -> Optional[int]:
    """The asking price in free text such as an unlabelled result card.

    A card also quotes fees and monthly payments. The price is the first
    amount of at least one million yen, which rules those out.
    """
    return next((v for v in yen_amounts(text) if v >= 1_000_000), None)


def parse_price(text: object) -> Optional[Price]:
    """Price from the value of a 価格 field. None when the text holds no price at all."""
    s = nfkc(text)
    amounts = yen_amounts(s)
    if not amounts:
        return Price(None, None, undisclosed=True) if _UNDISCLOSED.search(s) else None
    first = amounts[0]
    if len(amounts) >= 2 and re.search(r"[~〜～]|\d\s*-\s*\d|から|to\b", s):
        second = amounts[1]
        return Price(min(first, second), max(first, second))
    return Price(first, first)


# ---------------------------------------------------------------- area

_AREA_M2 = re.compile(rf"(?P<n>{_NUM})\s*(?:m2|m\^2|平米|平方メートル|sq\.?\s*m\b|sqm\b|square met)", re.I)
_AREA_TSUBO = re.compile(rf"(?P<n>{_NUM})\s*坪")
_AREA_HA = re.compile(rf"(?P<n>{_NUM})\s*(?:ha\b|ヘクタール)", re.I)


@dataclass(frozen=True)
class Area:
    """A floor or land area. `basis` is 'registered' (登記/公簿) or 'measured' (実測) when stated."""

    m2: Optional[float]
    m2_max: Optional[float] = None
    basis: Optional[str] = None
    from_tsubo: bool = False


def parse_area(text: object) -> Optional[Area]:
    s = nfkc(text)
    basis = None
    if re.search(r"実測", s):
        basis = "measured"
    elif re.search(r"登記|公簿", s):
        basis = "registered"
    # Text after "うち" itemises part of the total (basement, garage); it is not the total.
    head = re.split(r"うち|内訳", s)[0]
    metric = [_num(m.group("n")) for m in _AREA_M2.finditer(head)]
    if metric:
        is_range = len(metric) >= 2 and re.search(r"[~〜～]|\d\s*m2\s*-\s*\d", head) is not None
        return Area(metric[0], metric[1] if is_range else None, basis)
    hectares = _AREA_HA.search(head)
    if hectares:
        return Area(round(_num(hectares.group("n")) * 10000.0, 2), None, basis)
    tsubo = _AREA_TSUBO.search(head)
    if tsubo:
        return Area(round(_num(tsubo.group("n")) * TSUBO_M2, 2), None, basis, from_tsubo=True)
    return None


def to_tsubo(m2: float) -> float:
    return m2 / TSUBO_M2


# ---------------------------------------------------------------- built date

_ERAS = {"明治": 1868, "大正": 1912, "昭和": 1926, "平成": 1989, "令和": 2019, "M": 1868, "T": 1912, "S": 1926, "H": 1989, "R": 2019}
_MONTHS = {m: i + 1 for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}


@dataclass(frozen=True)
class Built:
    """Completion date. `approximate` when derived from an age such as 築35年."""

    year: Optional[int]
    month: Optional[int] = None
    approximate: bool = False

    def iso(self) -> Optional[str]:
        if self.year is None:
            return None
        return "%04d-%02d" % (self.year, self.month) if self.month else "%04d" % self.year


def parse_built(text: object, today: Optional[datetime.date] = None) -> Optional[Built]:
    # 1987[S62]年08月: the era year in brackets repeats the western year before it.
    s = re.sub(r"(?<=\d)\s*[\[(][MTSHR]\d{1,2}[\])]", "", nfkc(text))
    today = today or datetime.date.today()
    m = re.search(r"(?<!\d)(1[89]\d\d|20\d\d)\s*(?:年|/|\.|-)\s*(\d{1,2})?\s*月?", s)
    if m and (m.group(0).rstrip().endswith(("年", "月")) or m.group(2)):
        month = int(m.group(2)) if m.group(2) and 1 <= int(m.group(2)) <= 12 else None
        return Built(int(m.group(1)), month)
    m = re.search(r"(明治|大正|昭和|平成|令和)\s*(元|\d{1,2})\s*年(?:\s*(\d{1,2})\s*月)?", s)
    if m:
        n = 1 if m.group(2) == "元" else int(m.group(2))
        return Built(_ERAS[m.group(1)] + n - 1, int(m.group(3)) if m.group(3) else None)
    m = re.search(r"(?<![A-Za-z])([MTSHR])\s*(\d{1,2})\s*(?:[./年]\s*(\d{1,2}))?(?![\d階FfA-Za-z])", s)
    if m and re.search(r"築|建築|完成|竣工", s):
        return Built(_ERAS[m.group(1)] + int(m.group(2)) - 1, int(m.group(3)) if m.group(3) else None)
    m = re.search(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(1[89]\d\d|20\d\d)\b", s, re.I)
    if m:
        return Built(int(m.group(2)), _MONTHS[m.group(1).lower()])
    m = re.search(r"築\s*(?:後)?\s*(\d{1,3})\s*年", s)
    if m:
        return Built(today.year - int(m.group(1)), None, approximate=True)
    m = re.search(r"(?:built|completed|construction)\D{0,20}(1[89]\d\d|20\d\d)", s, re.I)
    if m:
        return Built(int(m.group(1)))
    m = re.fullmatch(r"\s*(1[89]\d\d|20\d\d)\s*", s)
    if m:
        return Built(int(m.group(1)))
    return None


# ---------------------------------------------------------------- structure

RC, SRC, STEEL, WOOD, BLOCK, OTHER, MIXED = "RC", "SRC", "S", "W", "CB", "other", "mixed"

_STRUCT_PATTERNS = [
    (SRC, re.compile(r"鉄骨鉄筋コンクリート|鉄骨鉄筋|(?<![A-Za-z])SRC(?![A-Za-z])|steel[- ]reinforced concrete", re.I)),
    (RC, re.compile(
        r"鉄筋コンクリート|鉄筋コンクリ|壁式コンクリート|プレキャストコンクリート|コンクリート造|(?<![A-Za-z])W?RC(?![A-Za-z])"
        r"|(?<![A-Za-z])PC(?:造|構造)|鉄筋(?!系)(?=造|\d|階|[^骨コ]|$)|reinforced concrete|\bconcrete\b",
        re.I,
    )),
    (BLOCK, re.compile(r"コンクリートブロック|ブロック造|(?<![A-Za-z])CB造", re.I)),
    (STEEL, re.compile(r"軽量鉄骨|重量鉄骨|鉄骨|(?<![A-Za-z])(?:LGS|S造|ALC)(?![A-Za-z])|スチール|\bsteel\b", re.I)),
    (WOOD, re.compile(
        r"木造|木質|在来工法|ツーバイ|2\s*[x×]\s*[46]|ログハウス|ログ造|丸太|(?<![A-Za-z])W造|\bwood(?:en)?\b|\btimber\b"
        # A bare 木 in a list of materials: 木・鉄筋コンクリート3階建, 鉄骨・木2階建.
        r"|(?<![一-龥ぁ-んァ-ヶ])木(?=\s*[・/、,+]|\s*\d+\s*階)|(?<=[・/、,+])\s*木(?![一-龥ぁ-んァ-ヶ])",
        re.I,
    )),
]


@dataclass(frozen=True)
class Structure:
    """Building structure. `kind` is one material, or 'mixed' with the materials in `parts`."""

    kind: Optional[str]
    parts: Tuple[str, ...] = field(default_factory=tuple)
    floors: Optional[int] = None
    basement: Optional[int] = None

    @property
    def has_concrete(self) -> bool:
        return RC in self.parts or SRC in self.parts


def parse_structure(text: object) -> Optional[Structure]:
    """Structure of the main building, from the value of a 構造 field (or any text that names one).

    Resort listings go on to describe outbuildings ("●別棟:木造平家建"). An
    annex in another material does not make the house a mixed structure, so
    the text is read only up to the first annex.
    """
    s = re.split(r"[●・\s]*(?:別棟|附属建物|付属建物|附属家|付属家)", nfkc(text))[0] or nfkc(text)
    rest = s
    parts: List[str] = []
    for kind, pattern in _STRUCT_PATTERNS:
        if pattern.search(rest):
            parts.append(kind)
            rest = pattern.sub(" ", rest)
    floors, basement = parse_floors(s)
    if not parts:
        if re.search(r"その他|\bother\b", s, re.I):
            return Structure(OTHER, (OTHER,), floors, basement)
        if floors is None and basement is None:
            return None
        return Structure(None, (), floors, basement)
    kind = parts[0] if len(parts) == 1 else MIXED
    return Structure(kind, tuple(parts), floors, basement)


def parse_floors(text: object) -> Tuple[Optional[int], Optional[int]]:
    """(storeys above ground, basement levels) from text such as 地下1階付3階建."""
    s = nfkc(text)
    basement = None
    m = re.search(r"地下\s*(\d{1,2})\s*階|B(\d)F?(?![A-Za-z0-9])|(\d)\s*basement", s, re.I)
    if m:
        basement = int(next(g for g in m.groups() if g))
    elif re.search(r"地下(?:室|付|あり)|半地下", s):
        basement = 1
    above = None
    if re.search(r"平屋|平家", s):
        above = 1
    m = re.search(r"地上\s*(\d{1,2})\s*階", s)
    if m:
        above = int(m.group(1))
    else:
        # 2階地下1階建 states the storeys before the basement: drop only the basement phrase.
        without_basement = re.sub(r"地下\s*\d{1,2}\s*階(?:付)?", "", s)
        m = re.search(r"(\d{1,2})\s*階\s*建|(\d{1,2})\s*(?:-|\s)?(?:stor(?:e)?ys?|stories|floors)\b", without_basement, re.I)
        if m:
            above = int(m.group(1) or m.group(2))
    return above, basement


def concrete_hint(text: object) -> bool:
    """True when free text (a title, sales copy) mentions reinforced concrete.

    A hint is not proof: the copy may describe a concrete garage under a
    wooden house. Callers must confirm against the 構造 field.
    """
    s = nfkc(text)
    return bool(re.search(r"鉄筋コンクリート|鉄骨鉄筋|(?<![A-Za-z])S?RC(?![A-Za-z])|コンクリート打ち?放し|打ち?放し|reinforced concrete", s, re.I))


# ---------------------------------------------------------------- address

_PREF = re.compile(r"(北海道|東京都|京都府|大阪府|[^\s、,]{2,3}県)")
_DESIGNATED = (
    "札幌", "仙台", "さいたま", "千葉", "横浜", "川崎", "相模原", "新潟", "静岡", "浜松",
    "名古屋", "京都", "大阪", "堺", "神戸", "岡山", "広島", "北九州", "福岡", "熊本",
)
# City names that contain 市 or 郡 before their final 市, which a first-match rule would cut short.
_ODD_CITIES = ("四日市市", "廿日市市", "野々市市", "蒲郡市", "小郡市", "大和郡山市", "郡山市", "郡上市")

_ROMAJI_PREF = {
    "hokkaido": "北海道", "aomori": "青森県", "iwate": "岩手県", "miyagi": "宮城県", "akita": "秋田県",
    "yamagata": "山形県", "fukushima": "福島県", "ibaraki": "茨城県", "tochigi": "栃木県", "gunma": "群馬県",
    "saitama": "埼玉県", "chiba": "千葉県", "tokyo": "東京都", "kanagawa": "神奈川県", "niigata": "新潟県",
    "toyama": "富山県", "ishikawa": "石川県", "fukui": "福井県", "yamanashi": "山梨県", "nagano": "長野県",
    "gifu": "岐阜県", "shizuoka": "静岡県", "aichi": "愛知県", "mie": "三重県", "shiga": "滋賀県",
    "kyoto": "京都府", "osaka": "大阪府", "hyogo": "兵庫県", "nara": "奈良県", "wakayama": "和歌山県",
    "tottori": "鳥取県", "shimane": "島根県", "okayama": "岡山県", "hiroshima": "広島県", "yamaguchi": "山口県",
    "tokushima": "徳島県", "kagawa": "香川県", "ehime": "愛媛県", "kochi": "高知県", "fukuoka": "福岡県",
    "saga": "佐賀県", "nagasaki": "長崎県", "kumamoto": "熊本県", "oita": "大分県", "miyazaki": "宮崎県",
    "kagoshima": "鹿児島県", "okinawa": "沖縄県",
}
PREFECTURES = tuple(_ROMAJI_PREF.values())
PREF_ROMAJI = {ja: en.capitalize() for en, ja in _ROMAJI_PREF.items()}

_TOKYO_WARDS_ROMAJI = {
    "chiyoda": "千代田区", "chuo": "中央区", "minato": "港区", "shinjuku": "新宿区", "bunkyo": "文京区",
    "taito": "台東区", "sumida": "墨田区", "koto": "江東区", "shinagawa": "品川区", "meguro": "目黒区",
    "ota": "大田区", "setagaya": "世田谷区", "shibuya": "渋谷区", "nakano": "中野区", "suginami": "杉並区",
    "toshima": "豊島区", "kita": "北区", "arakawa": "荒川区", "itabashi": "板橋区", "nerima": "練馬区",
    "adachi": "足立区", "katsushika": "葛飾区", "edogawa": "江戸川区",
}


@dataclass(frozen=True)
class Address:
    prefecture: Optional[str]
    municipality: Optional[str]
    rest: str

    @property
    def is_tokyo_ward(self) -> bool:
        return self.prefecture == "東京都" and bool(self.municipality) and self.municipality.endswith("区")


def _split_municipality(after_pref: str) -> Tuple[Optional[str], str]:
    for city in _ODD_CITIES:
        if after_pref.startswith(city):
            return city, after_pref[len(city):]
    m = re.match(r"(.{1,6}?郡)(.{1,8}?[町村])", after_pref)
    if m:
        return m.group(1) + m.group(2), after_pref[m.end():]
    m = re.match(r"(.{1,8}?市)", after_pref)
    if m:
        city = m.group(1)
        rest = after_pref[m.end():]
        if city[:-1] in _DESIGNATED:
            ward = re.match(r"(.{1,5}?区)", rest)
            if ward:
                return city + ward.group(1), rest[ward.end():]
        return city, rest
    m = re.match(r"(.{1,6}?区)", after_pref)
    if m:
        return m.group(1), after_pref[m.end():]
    m = re.match(r"(.{1,8}?[町村])", after_pref)
    if m:
        return m.group(1), after_pref[m.end():]
    return None, after_pref


def _strip_diacritics(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", s) if not unicodedata.combining(c))


def parse_address(text: object) -> Address:
    """Prefecture and municipality from a Japanese address, or from a romanised one."""
    s = re.sub(r"\s+", "", nfkc(text))
    s = re.sub(r"^〒?\d{3}-?\d{4}", "", s)
    m = _PREF.search(s)
    if m and m.start() <= 4:
        municipality, rest = _split_municipality(s[m.end():])
        return Address(m.group(1), municipality, rest)
    latin = _strip_diacritics(nfkc(text)).lower()
    if re.search(r"[a-z]", latin):
        pref = next((ja for en, ja in _ROMAJI_PREF.items() if re.search(rf"\b{en}\b", latin)), None)
        municipality = None
        if pref == "東京都":
            municipality = next(
                (ja for en, ja in _TOKYO_WARDS_ROMAJI.items() if re.search(rf"\b{en}(?:-|\s)?(?:ku|ward|city)\b", latin)), None
            )
        return Address(pref, municipality, squash(text))
    # No prefecture given: a bare ward or city name still helps deduplication.
    municipality, rest = _split_municipality(s)
    return Address(None, municipality, rest)


def municipality_key(municipality: Optional[str]) -> str:
    """Municipality without its county, since portals disagree on writing 北佐久郡."""
    return re.sub(r"^.{1,6}?郡(?=.+[町村]$)", "", municipality or "")


def town_key(rest: object) -> str:
    """The part of an address below the municipality, reduced to town and chome.

    Portals round addresses differently (南荻窪１, 南荻窪1丁目, 南荻窪一丁目12-3),
    so listings of one property compare equal only on this reduced form.
    """
    s = re.sub(r"\s+", "", nfkc(rest))
    s = re.sub(r"^(大字|字)", "", s)

    def kanji_chome(m: "re.Match[str]") -> str:
        digits = m.group(1)
        if digits == "十":
            return "10-"
        if digits.startswith("十"):
            return "1" + str(_KANJI_DIGITS[digits[1]]) + "-"
        return "".join(str(_KANJI_DIGITS[c]) for c in digits) + "-"

    s = re.sub(r"([一二三四五六七八九十〇]{1,2})丁目", kanji_chome, s)
    s = re.sub(r"(\d+)丁目", r"\1-", s)
    m = re.match(r"(.*?)(\d+)", s)
    if m:
        return m.group(1) + m.group(2)
    return s
