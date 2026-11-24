"""Location maps from the Geospatial Information Authority of Japan's open tiles.

Two views are made around the property's coordinates: an aerial photograph
close enough to show the lot and its neighbours, and a street map of the
surrounding area. The brochure lays the tiles out itself, so no imaging
library is needed.
"""

from __future__ import annotations

import json
import math
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote

from net import Fetcher
from store import BrochureError, Folder, write_json

TILE_URL = "https://cyberjapandata.gsi.go.jp/xyz/{layer}/{z}/{x}/{y}.{ext}"
GEOCODER = "https://msearch.gsi.go.jp/address-search/AddressSearch?q="
ATTRIBUTION = "Map tiles: Geospatial Information Authority of Japan (国土地理院 地理院タイル)"

# id -> (GSI layer, file type, zoom, tiles per side, default title)
VIEWS = {
    "aerial": ("seamlessphoto", "jpg", 18, 3, "Aerial photograph"),
    "area": ("std", "png", 16, 3, "Surrounding area"),
    "region": ("std", "png", 12, 3, "Wider region"),
}
DEFAULT_VIEWS = ("aerial", "area")


def tile_position(lat: float, lon: float, zoom: int) -> Tuple[float, float]:
    """Fractional tile coordinates of a point in the Web Mercator tiling."""
    n = 2 ** zoom
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def metres_per_pixel(lat: float, zoom: int) -> float:
    return 156543.03392 * math.cos(math.radians(lat)) / (2 ** zoom)


def _scale_bar(width_m: float) -> int:
    """A round distance of roughly a fifth of the map's width."""
    target = width_m / 5.0
    for candidate in (5000, 2000, 1000, 500, 200, 100, 50, 20, 10):
        if candidate <= target:
            return candidate
    return 5


def geocode(fetcher: Fetcher, address: str) -> Dict[str, Any]:
    """The GSI geocoder's first hit for an address: district precision, not the lot."""
    _kind, body = fetcher.get(GEOCODER + quote(address))
    hits = json.loads(body.decode("utf-8"))
    if not hits:
        raise BrochureError("the GSI geocoder found nothing for %r" % address)
    lon, lat = hits[0]["geometry"]["coordinates"]
    return {"lat": lat, "lon": lon, "matched": hits[0]["properties"].get("title", "")}


def build(
    folder: Folder, lat: float, lon: float, source: str, views: Tuple[str, ...] = DEFAULT_VIEWS, fetcher: Optional[Fetcher] = None
) -> List[Dict[str, Any]]:
    """Download the tiles for each view and write maps.json. `source` says where the coordinates came from."""
    if not (20.0 < lat < 46.5 and 122.0 < lon < 154.5):
        raise BrochureError("coordinates %.5f, %.5f are not in Japan (latitude first, then longitude)" % (lat, lon))
    fetcher = fetcher or Fetcher(delay_seconds=0.3)
    made = []
    for view in views:
        if view not in VIEWS:
            raise BrochureError("unknown map view %r; choose from %s" % (view, ", ".join(VIEWS)))
        layer, ext, zoom, side, title = VIEWS[view]
        x, y = tile_position(lat, lon, zoom)
        x0, y0 = int(x) - side // 2, int(y) - side // 2
        tiles = []
        for row in range(side):
            for col in range(side):
                url = TILE_URL.format(layer=layer, z=zoom, x=x0 + col, y=y0 + row, ext=ext)
                _kind, body = fetcher.get(url)
                path = folder.maps_dir / view / ("%d-%d.%s" % (row, col, ext))
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(body)
                tiles.append("maps/%s/%s" % (view, path.name))
        width_m = metres_per_pixel(lat, zoom) * 256 * side
        made.append(
            {
                "id": view,
                "title": title,
                "layer": layer,
                "zoom": zoom,
                "columns": side,
                "rows": side,
                "tiles": tiles,
                "marker": {"x": (x - x0) / side, "y": (y - y0) / side},
                "width_m": round(width_m, 1),
                "scale_bar_m": _scale_bar(width_m),
                "lat": lat,
                "lon": lon,
                "coordinates_from": source,
                "attribution": ATTRIBUTION,
            }
        )
    write_json(folder.maps, {"maps": made})
    return made
