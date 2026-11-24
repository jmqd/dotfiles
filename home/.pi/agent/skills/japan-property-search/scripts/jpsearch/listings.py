"""Turn raw JPX output (label/value pairs and card text) into listing records.

A listing record is a plain dict so it round-trips through JSON. Fields that
the source does not state are None; nothing is defaulted to a guess.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Optional

import text

# Canonical field -> labels that carry it, Japanese first, then English for the
# foreigner-facing sites. Compared after label_key() folding.
LABELS: Dict[str, tuple] = {
    "price": ("価格", "販売価格", "物件価格", "売買価格", "売出価格", "price", "saleprice", "askingprice"),
    "address": ("所在地", "住所", "物件所在地", "所在", "location", "address"),
    "access": (
        "交通", "沿線・駅", "最寄駅", "最寄り駅", "アクセス", "交通機関",
        "access", "transportation", "neareststation", "station", "transport",
    ),
    "land": ("土地面積", "敷地面積", "土地", "区画面積", "landarea", "landsize", "lotsize", "lotarea", "land"),
    "building": (
        "建物面積", "延床面積", "延べ床面積", "建物延床面積", "建物", "延床", "床面積",
        "floorarea", "buildingarea", "totalfloorarea", "buildingsize", "size", "grossfloorarea",
    ),
    "layout": ("間取り", "間取", "layout", "floorplan", "bedrooms"),
    "built": (
        "築年月", "築年数", "建築年月", "完成時期", "築年", "竣工", "建築年",
        "yearbuilt", "built", "completion", "constructionyear", "completed", "constructiondate",
    ),
    "structure": (
        "構造", "建物構造", "構造・工法", "構造・階建", "構造・規模", "構造/階建", "構造・階数", "建物の構造",
        "structure", "construction", "buildingstructure",
    ),
    "floors": ("階建", "階数", "建物階数", "階建て", "floors", "stories", "storeys"),
    "land_right": (
        "土地権利", "権利", "権利形態", "土地の権利形態", "土地の権利",
        "landrights", "landtenure", "tenure", "landownership",
    ),
    "zoning": ("用途地域", "zoning"),
    "coverage_far": ("建ぺい率・容積率", "建蔽率・容積率", "建ぺい率/容積率", "建ぺい率", "建蔽率"),
    "far": ("容積率",),
    "road": ("接道", "接道状況", "道路", "前面道路", "私道負担・道路", "接道状況・道路"),
    "land_category": ("地目",),
    "city_planning": ("都市計画", "都市計画区域"),
    "status": ("現況", "建物現況", "currentstatus", "status"),
    "handover": ("引渡", "引渡し", "引渡時期", "引渡可能時期", "引き渡し", "入居時期"),
    "transaction": ("取引態様", "取引形態"),
    "restrictions": ("法令制限", "その他制限事項", "法令上の制限", "その他法令上の制限", "制限"),
    "remarks": ("備考", "その他概要・特記事項", "特記事項", "その他", "remarks", "notes"),
    "parking": ("駐車場", "駐車スペース", "parking"),
    "renovation": ("リフォーム", "リフォーム履歴", "改装"),
    "agent": (
        "会社名", "商号", "取扱会社", "お問い合せ先", "お問い合わせ先", "問い合わせ先", "取扱店舗", "掲載会社",
        "情報提供会社", "会社概要",
    ),
    "updated": ("情報更新日", "情報提供日", "情報公開日", "情報登録日", "更新日", "登録日"),
    "listing_no": ("物件番号", "物件no", "管理番号", "propertyid", "referencenumber"),
    "kind": ("物件種目", "物件種別", "種別", "種目", "propertytype", "type"),
    "villa_estate": ("別荘地名", "別荘地"),
    "water": ("水道", "上水道", "飲用水"),
    "sewer": ("下水", "排水", "汚水"),
    "gas": ("ガス",),
    "hot_spring": ("温泉",),
    "management_fee": ("管理費", "管理費等"),
    "altitude": ("標高",),
}

_LABEL_TO_FIELD: Dict[str, str] = {}
for _field, _labels in LABELS.items():
    for _label in _labels:
        _LABEL_TO_FIELD.setdefault(_label, _field)

# Labels that only mean the field when nothing more specific was found, because
# they are also everyday words on a page (土地 as a section heading, for one).
_WEAK = {"土地", "建物", "延床", "size", "land", "type", "status", "その他", "制限", "権利", "station", "built"}

# Fields that describe the property in prose. Flags are read from these and
# from the title, never from a whole page, whose boilerplate mentions
# leaseholds and disclosures that have nothing to do with this property.
_PROSE_FIELDS = (
    "land_right", "restrictions", "remarks", "status", "road", "city_planning", "zoning", "land_category",
    "structure", "handover", "transaction", "kind",
)

_PLACEHOLDER = re.compile(r"^[\s\-ー－―—─]*$")

# What a field's value must contain to be believed. Label matching finds
# look-alikes too: on a result card 前面道路 is also a photo category, and the
# text beside it is the next category, not a road.
_PLAUSIBLE = {
    "price": re.compile(r"\d|応談|相談|未定|ask|request", re.I),
    "land": re.compile(r"\d"),
    "building": re.compile(r"\d"),
    "built": re.compile(r"\d|新築"),
    "structure": re.compile(r"造|RC|鉄|木|コンクリ|ブロック|階|平屋|concrete|steel|wood|timber|stor", re.I),
    "road": re.compile(r"\d|公道|私道|接道|国道|県道|市道|町道|村道|road", re.I),
    "land_right": re.compile(r"所有|借地|地上権|賃借|freehold|lease|owner", re.I),
    "zoning": re.compile(r"地域|住居|商業|工業|低層|中高層|指定|無|zone|residential|commercial|industrial", re.I),
}


def label_key(label: object) -> str:
    """A label reduced for lookup: first line only, folded to ASCII, lower case, no spaces or colons.

    Portals put tooltip text ("ヒント") on a second line of the label cell.
    """
    first_line = text.nfkc(label).strip().split("\n")[0]
    return re.sub(r"[\s:]", "", first_line.lower())


def clean_value(value: object) -> str:
    """A field value without link captions such as '[ 乗り換え案内 ]' and without placeholders."""
    s = text.nfkc(value)
    s = re.sub(r"\[\s*[□■▼▶>]?[^\[\]\n]{0,24}\]", " ", s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r" *\n *", "\n", s).strip()
    return "" if _PLACEHOLDER.match(s) else s


def _field_for(key: str) -> Optional[str]:
    return _LABEL_TO_FIELD.get(key) or _LABEL_TO_FIELD.get(re.sub(r"\(.*$", "", key))


def _split_combined(key: str, value: str) -> List[tuple]:
    """Pairs from a combined label such as 土地面積/間取り, whose value has one line per part."""
    parts = [p for p in key.split("/") if p]
    lines = [line for line in value.split("\n") if line.strip()]
    if len(parts) < 2 or len(parts) != len(lines) or not all(_field_for(p) for p in parts):
        return []
    return list(zip(parts, lines))


def fields_from_pairs(pairs: Iterable[Dict[str, Any]]) -> Dict[str, str]:
    """Canonical field -> raw value. The first strong label wins; weak labels only fill gaps."""
    strong: Dict[str, str] = {}
    weak: Dict[str, str] = {}
    for pair in pairs:
        key = label_key(pair.get("label"))
        value = clean_value(pair.get("value"))
        if not value:
            continue
        entries = [(key, value)] if _field_for(key) else _split_combined(key, value)
        for part_key, part_value in entries:
            field = _field_for(part_key)
            check = _PLAUSIBLE.get(field or "")
            if check is not None and not check.search(part_value):
                continue
            target = weak if part_key in _WEAK else strong
            target.setdefault(field, part_value)
    for field, value in weak.items():
        strong.setdefault(field, value)
    return strong


_T_NUM = r"\d[\d,]*(?:\.\d+)?"
_T_UNIT = r"(?:m2|平米|坪)"


def fields_from_text(card_text: object) -> Dict[str, str]:
    """Best-effort fields from a result card that has no label/value markup.

    Structure is deliberately absent: card copy such as 'RC造の車庫' describes
    a garage, so only a labelled 構造 field counts as the structure.
    """
    s = text.nfkc(card_text)
    out: Dict[str, str] = {}
    m = re.search(rf"(?:土地|敷地)(?:面積)?[^\d\n]{{0,8}}({_T_NUM}\s*{_T_UNIT}[^\n]{{0,24}})", s)
    if m:
        out["land"] = m.group(1)
    m = re.search(rf"(?:建物|延床|延べ床|床)(?:面積)?[^\d\n]{{0,8}}({_T_NUM}\s*{_T_UNIT}[^\n]{{0,24}})", s)
    if m:
        out["building"] = m.group(1)
    m = re.search(r"(?:価格|販売価格)[^\d\n]{0,6}([^\n]{1,30}円)", s)
    if m:
        out["price"] = m.group(1)
    else:
        amounts = text.yen_amounts(s)
        if amounts:
            out["price"] = "%d円" % max(amounts)
    m = re.search(r"((?:北海道|東京都|京都府|大阪府|\S{2,3}県)\S{2,40})", s)
    if m:
        out["address"] = m.group(1)
    m = re.search(r"((?:1[89]|20)\d\d年\s*\d{1,2}月|(?:昭和|平成|令和)\s*(?:元|\d{1,2})年(?:\s*\d{1,2}月)?|築\s*\d{1,3}年)", s)
    if m:
        out["built"] = m.group(1)
    m = re.search(r"(?<![\dA-Za-z])(\d{1,2}\s*S?L{0,2}D{0,2}K{1,2}(?:\s*\+\s*\d?S)?)(?![A-Za-z])", s)
    if m:
        out["layout"] = m.group(1)
    m = re.search(r"([^\n]{0,20}(?:線|ライン)[^\n]{0,24}(?:駅|」)[^\n]{0,16}(?:徒歩|歩|バス|車)\s*\d+\s*分)", s)
    if m:
        out["access"] = m.group(1).strip()
    return out


_FLAG_PATTERNS = [
    ("leasehold", r"借地|地上権|賃借権|leasehold"),
    ("no_rebuild", r"再建築不可|建築不可"),
    ("urbanisation_control", r"市街化調整"),
    ("setback", r"セットバック|SB\s*\d|要後退"),
    ("notice", r"告知事項|心理的瑕疵"),
    ("tenant_occupied", r"賃貸中|オーナーチェンジ"),
    ("under_negotiation", r"商談中|申込あり|申込み有|契約予定|成約済"),
    ("unregistered_part", r"未登記"),
    ("slope_or_retaining_wall", r"がけ|崖|擁壁|急傾斜|法面"),
    ("hazard_zone", r"土砂災害(?:特別)?警戒区域|津波災害警戒区域|浸水想定|レッドゾーン|イエローゾーン"),
    ("farmland", r"農地|農振"),
    ("natural_park", r"国立公園|国定公園|自然公園"),
    ("non_conforming", r"既存不適格|違反建築"),
]


def _flags(listing: Dict[str, Any], haystack: str) -> List[str]:
    flags = [name for name, pattern in _FLAG_PATTERNS if re.search(pattern, haystack, re.I)]
    right = listing.get("land_right") or ""
    if "leasehold" in flags and re.search(r"所有権|freehold", right, re.I) and not re.search(r"借地|地上権|賃借権", right):
        # The tenure field says freehold; the word came from a remark about something else.
        flags.remove("leasehold")
    year, month = listing.get("built_year"), listing.get("built_month")
    if year is not None and (year < 1981 or (year == 1981 and (month or 12) <= 5)):
        # Building permits before June 1981 followed the old seismic code (旧耐震).
        flags.append("pre_1981_seismic_code")
    return flags


def _agent_name(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    lines = [line.strip() for line in raw.split("\n") if line.strip()]
    company = re.compile(
        r"株式会社|\(株\)|有限会社|\(有\)|合同会社|不動産|リアルティ|ハウス|ホーム|リゾート|エステート|商事|地所|住宅"
        r"|realty|estate|homes?\b|inc\.?|co\.,? ?ltd",
        re.I,
    )
    for line in lines:
        if company.search(line):
            return line[:80]
    return lines[0][:80] if lines else None


_PASSTHROUGH = (
    "land_right", "zoning", "coverage_far", "far", "road", "land_category", "city_planning", "status", "handover",
    "transaction", "restrictions", "remarks", "parking", "renovation", "updated", "listing_no", "kind",
    "villa_estate", "water", "sewer", "gas", "hot_spring", "management_fee", "altitude",
)


def normalise(
    source: str,
    listing_type: str,
    url: str,
    title: object,
    pairs: Iterable[Dict[str, Any]],
    card_text: object,
    image: Optional[str],
    seen: str,
) -> Dict[str, Any]:
    """One listing record.

    `card_text` is the text of a result card, used when the card has no
    label markup. Pass None for a detail page: a whole page's text holds
    other listings' prices and addresses.
    """
    raw = fields_from_pairs(pairs)
    if card_text is not None:
        for field, value in fields_from_text(card_text).items():
            raw.setdefault(field, value)

    price = text.parse_price(raw.get("price"))
    land = text.parse_area(raw.get("land"))
    building = text.parse_area(raw.get("building"))
    built = text.parse_built(raw.get("built"))
    structure_text = raw.get("structure")
    structure = text.parse_structure(structure_text) if structure_text else None
    floors, basement = text.parse_floors(raw.get("floors")) if raw.get("floors") else (None, None)
    address = text.parse_address(raw.get("address")) if raw.get("address") else text.Address(None, None, "")

    title_text = text.squash(title)
    prose = [title_text, text.nfkc(card_text)] + [raw.get(f) or "" for f in _PROSE_FIELDS]
    haystack = "\n".join(prose)

    listing: Dict[str, Any] = {
        "source": source,
        "url": url,
        "listing_type": listing_type,
        "title": title_text[:200],
        "price_jpy": price.low if price else None,
        "price_max_jpy": price.high if price and price.high != price.low else None,
        "price_undisclosed": bool(price and price.undisclosed),
        "price_text": raw.get("price"),
        "address": text.squash(raw.get("address")) or None,
        "prefecture": address.prefecture,
        "municipality": address.municipality,
        "town": text.town_key(address.rest) if address.municipality else None,
        "land_m2": land.m2 if land else None,
        "land_basis": land.basis if land else None,
        "land_text": raw.get("land"),
        "building_m2": building.m2 if building else None,
        "building_basis": building.basis if building else None,
        "building_text": raw.get("building"),
        "layout": text.squash(raw.get("layout"))[:40] or None,
        "built_year": built.year if built else None,
        "built_month": built.month if built else None,
        "built_approximate": bool(built and built.approximate),
        "built_text": raw.get("built"),
        "structure": structure.kind if structure else None,
        "structure_parts": list(structure.parts) if structure else [],
        "structure_text": structure_text,
        "floors": structure.floors if structure and structure.floors is not None else floors,
        "basement": structure.basement if structure and structure.basement is not None else basement,
        "concrete_hint": text.concrete_hint(haystack),
        "access": text.squash(raw.get("access"))[:300] or None,
        "agent": _agent_name(raw.get("agent")),
        "image": image,
        "has_detail": False,
        "seen": seen,
    }
    for field in _PASSTHROUGH:
        value = raw.get(field)
        listing[field] = text.squash(value)[:400] if value else None
    listing["flags"] = _flags(listing, haystack)
    return listing


# Fields a detail page states with more authority than a result card.
_DETAIL_WINS = (
    "structure", "structure_parts", "structure_text", "floors", "basement", "agent", "access",
) + _PASSTHROUGH
# Fields the card usually has right; the detail page only fills gaps.
_DETAIL_FILLS = (
    "price_jpy", "price_max_jpy", "price_text", "address", "prefecture", "municipality", "town", "land_m2",
    "land_basis", "land_text", "building_m2", "building_basis", "building_text", "layout", "built_year",
    "built_month", "built_text", "image", "title",
)


def merge_detail(listing: Dict[str, Any], detail: Dict[str, Any]) -> Dict[str, Any]:
    """The card's listing completed with what its detail page states."""
    merged = dict(listing)
    for field in _DETAIL_WINS:
        if detail.get(field) not in (None, "", []):
            merged[field] = detail[field]
    for field in _DETAIL_FILLS:
        if merged.get(field) in (None, "", []) and detail.get(field) not in (None, "", []):
            merged[field] = detail[field]
    merged["concrete_hint"] = bool(listing.get("concrete_hint") or detail.get("concrete_hint"))
    merged["flags"] = sorted(set(listing.get("flags") or []) | set(detail.get("flags") or []))
    merged["has_detail"] = True
    for field in ("coords", "image_count"):
        if detail.get(field) is not None:
            merged[field] = detail[field]
    return merged


def from_detail_capture(source: str, listing_type: str, capture: Dict[str, Any], seen: str) -> Dict[str, Any]:
    """A listing record from JPX.detail() output."""
    images = [i for i in capture.get("images") or [] if not i.get("chrome") and not i.get("tiny")]
    record = normalise(
        source,
        listing_type,
        capture.get("url") or "",
        capture.get("h1") or capture.get("title"),
        capture.get("pairs") or [],
        None,
        images[0]["url"] if images else None,
        seen,
    )
    coords = capture.get("coords") or []
    if coords:
        record["coords"] = {"lat": coords[0]["lat"], "lon": coords[0]["lon"], "datum": coords[0].get("datum", "unknown")}
    record["image_count"] = len({(i.get("candidates") or [i["url"]])[0] for i in images})
    record["has_detail"] = True
    return record
