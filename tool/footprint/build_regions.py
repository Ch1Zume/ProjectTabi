"""Build the boundary assets used by the footprint map.

Outputs (under assets/footprint/):
  world.ptrg            countries for the 3D globe (China worldview)
  admin1/<ISO3>.ptrg    first-level divisions per country
  admin2/<ISO3>.ptrg    city-level divisions (CHN, JPN only)

Sources:
  Natural Earth 10m admin 0 (China worldview) and admin 1, public domain.
  国土数値情報（行政区域データ）N03, simplified by smartnews-smri/japan-topography.
  DataV.GeoAtlas province and prefecture boundaries of China.

Usage:
  python tool/footprint/build_regions.py --cache <download dir>

Requires shapely>=2.1 and pyshp.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import urllib.request
import zipfile
from pathlib import Path

import shapefile
import shapely
from shapely.geometry import MultiPolygon, Polygon, shape
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets' / 'footprint'

NE_BASE = 'https://naciscdn.org/naturalearth/10m/cultural'
JP_BASE = (
    'https://raw.githubusercontent.com/smartnews-smri/japan-topography/main/'
    'data/municipality/geojson/s0010'
)
DATAV_BASE = 'https://geo.datav.aliyun.com/areas_v3/bound'

# Units drawn separately by Natural Earth that belong to China in the
# China worldview.
CHINA_MERGED_UNITS = {'HKG', 'MAC', 'SCR'}
COUNTRY_NAME_OVERRIDES = {
    'CHN': '中国',
    'KOR': '韩国',
    'PRK': '朝鲜',
    'MNG': '蒙古',
    'ARE': '阿联酋',
    'IOA': '澳属印度洋领地',
}
# Countries whose admin 1 data comes from dedicated sources.
CUSTOM_ADMIN_COUNTRIES = {'CHN', 'JPN'}
# Chinese municipalities and SARs are shown as city-level leaves.
CHINA_LEAF_PROVINCES = {110000, 120000, 310000, 500000, 710000, 810000, 820000}

QUANT = 1e5
MAGIC = b'PTRG'
VERSION = 1


# ---------------------------------------------------------------- download --

def fetch(url: str, target: Path) -> Path:
    if target.exists() and target.stat().st_size > 0:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    print(f'download {url}')
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(request, timeout=120) as response:
        target.write_bytes(response.read())
    return target


def fetch_ne(cache: Path, name: str) -> Path:
    archive = fetch(f'{NE_BASE}/{name}.zip', cache / 'ne' / f'{name}.zip')
    folder = cache / 'ne' / name
    if not (folder / f'{name}.shp').exists():
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(folder)
    return folder / f'{name}.shp'


# ---------------------------------------------------------------- geometry --

def polygons_of(geometry) -> list[Polygon]:
    if geometry is None or geometry.is_empty:
        return []
    if isinstance(geometry, Polygon):
        return [geometry]
    if isinstance(geometry, MultiPolygon):
        return list(geometry.geoms)
    return [g for part in getattr(geometry, 'geoms', []) for g in polygons_of(part)]


def clean(geometry):
    if geometry is None or geometry.is_empty:
        return geometry
    if not geometry.is_valid:
        geometry = shapely.make_valid(geometry)
    return MultiPolygon(polygons_of(geometry)) if geometry.geom_type not in (
        'Polygon',
        'MultiPolygon',
    ) else geometry


def drop_specks(geometry, min_area: float):
    """Removes islands smaller than [min_area] but always keeps the largest."""
    parts = polygons_of(geometry)
    if not parts:
        return geometry
    largest = max(parts, key=lambda p: p.area)
    kept = [p for p in parts if p is largest or p.area >= min_area]
    return kept[0] if len(kept) == 1 else MultiPolygon(kept)


def simplify_coverage(geometries: list, tolerance: float) -> list:
    """Simplifies polygons that share borders without opening gaps."""
    try:
        result = shapely.coverage_simplify(
            shapely.GeometryCollection([g for g in geometries]).geoms,
            tolerance,
        )
        result = [clean(g) for g in result]
        if all(g is not None and not g.is_empty for g in result):
            return result
    except Exception as error:  # noqa: BLE001 - falls back below.
        print(f'  coverage simplify failed ({error}); simplifying per feature')
    return [clean(g.simplify(tolerance, preserve_topology=True)) for g in geometries]


def label_point(geometry) -> tuple[float, float]:
    largest = max(polygons_of(geometry), key=lambda p: p.area)
    point = largest.representative_point()
    return point.x, point.y


# ------------------------------------------------------------------ format --

class Writer:
    def __init__(self):
        self.buffer = bytearray()

    def varint(self, value: int):
        if value < 0:
            raise ValueError(value)
        while True:
            byte = value & 0x7F
            value >>= 7
            if value:
                self.buffer.append(byte | 0x80)
            else:
                self.buffer.append(byte)
                return

    def zigzag(self, value: int):
        self.varint((value << 1) ^ (value >> 63))

    def string(self, value: str):
        data = value.encode('utf-8')
        self.varint(len(data))
        self.buffer.extend(data)

    def coordinates(self, coords):
        points = [(round(x * QUANT), round(y * QUANT)) for x, y in coords]
        deduped = []
        for point in points:
            if not deduped or deduped[-1] != point:
                deduped.append(point)
        if len(deduped) > 1 and deduped[0] == deduped[-1]:
            deduped.pop()
        self.varint(len(deduped))
        px = py = 0
        for x, y in deduped:
            self.zigzag(x - px)
            self.zigzag(y - py)
            px, py = x, y


def write_regions(path: Path, features: list[dict], lines: list = ()):
    """Writes the PTRG format read by lib/footprint/region_codec.dart.

    header: "PTRG" u8 version, varint featureCount
    feature: id, name, parentId (strings), varint flags,
             zigzag labelLon/labelLat (1e-5 deg),
             varint polygonCount, per polygon varint ringCount,
             per ring varint pointCount + zigzag delta coordinates
    trailer: varint lineCount, per line the same point encoding
    """
    writer = Writer()
    writer.buffer.extend(MAGIC)
    writer.buffer.extend(struct.pack('<B', VERSION))
    writer.varint(len(features))
    for feature in features:
        geometry = feature['geometry']
        writer.string(feature['id'])
        writer.string(feature['name'])
        writer.string(feature.get('parent', ''))
        writer.varint(1 if feature.get('has_children') else 0)
        lon, lat = feature.get('label') or label_point(geometry)
        writer.zigzag(round(lon * QUANT))
        writer.zigzag(round(lat * QUANT))
        polygons = [p for p in polygons_of(geometry) if len(p.exterior.coords) >= 4]
        writer.varint(len(polygons))
        for polygon in polygons:
            polygon = shapely.geometry.polygon.orient(polygon, 1.0)
            rings = [polygon.exterior, *polygon.interiors]
            writer.varint(len(rings))
            for ring in rings:
                writer.coordinates(ring.coords)
    writer.varint(len(lines))
    for line in lines:
        writer.coordinates(line.coords)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(writer.buffer))
    return len(writer.buffer)


def vertex_count(features) -> int:
    return sum(
        len(ring.coords)
        for f in features
        for p in polygons_of(f['geometry'])
        for ring in [p.exterior, *p.interiors]
    )


# --------------------------------------------------------------- countries --

def load_countries(cache: Path) -> dict[str, dict]:
    reader = shapefile.Reader(str(fetch_ne(cache, 'ne_10m_admin_0_countries_chn')))
    countries: dict[str, dict] = {}
    for record, shp in zip(reader.records(), reader.shapes()):
        code = record['ADM0_A3']
        if code in CHINA_MERGED_UNITS:
            code = 'CHN'
        geometry = clean(shape(shp.__geo_interface__))
        name = COUNTRY_NAME_OVERRIDES.get(code) or record['NAME_ZH'] or record['NAME']
        if code in countries:
            countries[code]['geometry'] = clean(
                unary_union([countries[code]['geometry'], geometry])
            )
        else:
            countries[code] = {
                'id': code,
                'name': name,
                'geometry': geometry,
                'label': (record['LABEL_X'], record['LABEL_Y'])
                if record['LABEL_X'] or record['LABEL_Y']
                else None,
            }
    countries['CHN']['label'] = None
    return countries


# ------------------------------------------------------------ admin 1 (NE) --

def admin1_tolerance(geometry) -> float:
    minx, miny, maxx, maxy = geometry.bounds
    diagonal = math.hypot(maxx - minx, maxy - miny)
    return min(0.03, max(0.002, diagonal / 1500))


def build_ne_admin1(cache: Path, countries: dict[str, dict]) -> set[str]:
    reader = shapefile.Reader(
        str(fetch_ne(cache, 'ne_10m_admin_1_states_provinces'))
    )
    grouped: dict[str, list[dict]] = {}
    for record, shp in zip(reader.records(), reader.shapes()):
        code = record['adm0_a3']
        if code in CUSTOM_ADMIN_COUNTRIES or code in CHINA_MERGED_UNITS or code == 'TWN':
            continue
        geometry = clean(shape(shp.__geo_interface__))
        if geometry is None or geometry.is_empty:
            continue
        identifier = record['iso_3166_2'] or record['adm1_code']
        if not identifier or identifier.endswith('~'):
            identifier = record['adm1_code']
        grouped.setdefault(code, []).append(
            {
                'id': identifier,
                'name': record['name_zh'] or record['name'],
                'parent': code,
                'geometry': geometry,
            }
        )

    written = set()
    for code, features in sorted(grouped.items()):
        country = countries.get(code)
        if country is None or len(features) < 2:
            continue
        # Clip to the China-worldview country outline so disputed areas
        # follow the same boundary as the globe.
        outline = country['geometry'].buffer(0)
        clipped = []
        for feature in features:
            geometry = clean(feature['geometry'].intersection(outline))
            if geometry is None or geometry.is_empty or geometry.area < 1e-6:
                continue
            if geometry.area < feature['geometry'].area * 0.1:
                continue  # Mostly outside the country in this worldview.
            clipped.append({**feature, 'geometry': geometry})
        if len(clipped) < 2:
            continue
        seen: dict[str, int] = {}
        for feature in clipped:
            count = seen.get(feature['id'], 0)
            seen[feature['id']] = count + 1
            if count:
                feature['id'] = f"{feature['id']}~{count}"
        tolerance = admin1_tolerance(outline)
        simplified = simplify_coverage([f['geometry'] for f in clipped], tolerance)
        result = []
        for feature, geometry in zip(clipped, simplified):
            geometry = drop_specks(geometry, (tolerance * 2) ** 2)
            if geometry is None or geometry.is_empty:
                continue
            result.append({**feature, 'geometry': geometry})
        write_regions(OUT / 'admin1' / f'{code}.ptrg', result)
        written.add(code)
    print(f'admin1 (Natural Earth): {len(written)} countries')
    return written


# ------------------------------------------------------------------- Japan --

def build_japan(cache: Path, countries: dict[str, dict]) -> None:
    outline = countries['JPN']['geometry'].buffer(0.05)
    municipalities: dict[str, dict] = {}
    for prefecture in range(1, 48):
        name = f'N03-21_{prefecture:02d}_210101.json'
        data = json.loads(fetch(f'{JP_BASE}/{name}', cache / 'jp' / name).read_text())
        for feature in data['features']:
            props = feature['properties']
            code = props.get('N03_007')
            ward_or_city = props.get('N03_004')
            if not code or not ward_or_city:
                continue
            city = props.get('N03_003') or ''
            if code[:2] == '13' and '13101' <= code <= '13123':
                key, label = '13100', '東京都区部'
            elif city.endswith('市') and ward_or_city.endswith('区'):
                key, label = code[:4] + '0', city
            else:
                key, label = code, ward_or_city
            geometry = clean(shape(feature['geometry']))
            entry = municipalities.setdefault(
                key,
                {
                    'id': f'JP-{key}',
                    'name': label,
                    'parent': f'JP-{key[:2]}',
                    'prefecture': props['N03_001'],
                    'parts': [],
                },
            )
            entry['parts'].append(geometry)

    cities = []
    for entry in municipalities.values():
        geometry = clean(unary_union(entry['parts']).buffer(0))
        if not outline.contains(geometry.representative_point()):
            continue  # Outside Japan in the China worldview.
        cities.append({**entry, 'geometry': geometry})
    cities.sort(key=lambda f: f['id'])

    prefectures = []
    for code in sorted({f['parent'] for f in cities}):
        members = [f for f in cities if f['parent'] == code]
        prefectures.append(
            {
                'id': code,
                'name': members[0]['prefecture'],
                'parent': 'JPN',
                'has_children': True,
                'geometry': clean(
                    unary_union([m['geometry'] for m in members]).buffer(0)
                ),
            }
        )

    simplified = simplify_coverage([f['geometry'] for f in prefectures], 0.008)
    for feature, geometry in zip(prefectures, simplified):
        feature['geometry'] = drop_specks(geometry, 0.0004)
    simplified = simplify_coverage([f['geometry'] for f in cities], 0.0015)
    for feature, geometry in zip(cities, simplified):
        feature['geometry'] = drop_specks(geometry, 0.00002)

    size1 = write_regions(OUT / 'admin1' / 'JPN.ptrg', prefectures)
    size2 = write_regions(OUT / 'admin2' / 'JPN.ptrg', cities)
    print(
        f'JPN: {len(prefectures)} prefectures ({size1 // 1024} KB), '
        f'{len(cities)} municipalities ({size2 // 1024} KB)'
    )


# ------------------------------------------------------------------- China --

def build_china(cache: Path) -> list:
    provinces_data = json.loads(
        fetch(f'{DATAV_BASE}/100000_full.json', cache / 'cn' / '100000_full.json').read_text()
    )
    cities_data = json.loads(
        fetch(
            f'{DATAV_BASE}/100000_full_city.json',
            cache / 'cn' / '100000_full_city.json',
        ).read_text()
    )

    lines = []
    provinces = []
    for feature in provinces_data['features']:
        props = feature['properties']
        geometry = shape(feature['geometry'])
        if str(props.get('adcode', '')).endswith('_JD'):
            lines.extend(
                p.exterior for p in polygons_of(geometry)
            )  # Nine-dash line segments are stored as thin polygons.
            continue
        adcode = int(props['adcode'])
        provinces.append(
            {
                'id': f'CN-{adcode}',
                'name': props['name'],
                'parent': 'CHN',
                'has_children': adcode not in CHINA_LEAF_PROVINCES,
                'label': tuple(props.get('centroid') or props['center']),
                'geometry': clean(geometry.buffer(0)),
            }
        )

    cities = []
    for feature in cities_data['features']:
        props = feature['properties']
        if props.get('level') != 'city' or not feature.get('geometry'):
            continue
        parent = int(props['parent']['adcode'])
        if parent in CHINA_LEAF_PROVINCES:
            continue
        cities.append(
            {
                'id': f"CN-{props['adcode']}",
                'name': props['name'],
                'parent': f'CN-{parent}',
                'label': tuple(props.get('centroid') or props['center']),
                'geometry': clean(shape(feature['geometry']).buffer(0)),
            }
        )

    simplified = simplify_coverage([f['geometry'] for f in provinces], 0.02)
    for feature, geometry in zip(provinces, simplified):
        feature['geometry'] = drop_specks(geometry, 0.0004)
    simplified = simplify_coverage([f['geometry'] for f in cities], 0.004)
    for feature, geometry in zip(cities, simplified):
        feature['geometry'] = drop_specks(geometry, 0.00002)

    size1 = write_regions(OUT / 'admin1' / 'CHN.ptrg', provinces, lines)
    size2 = write_regions(OUT / 'admin2' / 'CHN.ptrg', cities, lines)
    print(
        f'CHN: {len(provinces)} provinces ({size1 // 1024} KB), '
        f'{len(cities)} cities ({size2 // 1024} KB)'
    )
    return lines


# ------------------------------------------------------------------- world --

def build_world(countries: dict[str, dict], admin1: set[str], lines: list) -> None:
    features = sorted(countries.values(), key=lambda f: f['id'])
    simplified = simplify_coverage([f['geometry'] for f in features], 0.08)
    result = []
    for feature, geometry in zip(features, simplified):
        geometry = drop_specks(geometry, 0.004)
        if geometry is None or geometry.is_empty:
            continue
        result.append(
            {
                'id': feature['id'],
                'name': feature['name'],
                'has_children': feature['id'] in admin1,
                'label': feature['label'],
                'geometry': geometry,
            }
        )
    world_lines = [line.simplify(0.02) for line in lines]
    size = write_regions(OUT / 'world.ptrg', result, world_lines)
    print(
        f'world: {len(result)} countries, {vertex_count(result)} vertices '
        f'({size // 1024} KB)'
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    for folder in ('admin1', 'admin2'):
        for old in (OUT / folder).glob('*.ptrg'):
            old.unlink()

    countries = load_countries(args.cache)
    admin1 = build_ne_admin1(args.cache, countries)
    build_japan(args.cache, countries)
    lines = build_china(args.cache)
    admin1 |= CUSTOM_ADMIN_COUNTRIES
    build_world(countries, admin1, lines)
    return 0


if __name__ == '__main__':
    sys.exit(main())
