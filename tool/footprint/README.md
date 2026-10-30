# 足迹地图边界数据

`build_regions.py` 下载原始边界并生成 `assets/footprint/` 下的 PTRG 二进制文件，供“足迹”页的地球与分级地图使用。

```bash
python3 -m venv .venv && .venv/bin/pip install "shapely>=2.1" pyshp
.venv/bin/python tool/footprint/build_regions.py --cache /path/to/download-cache
```

| 输出 | 内容 | 来源 |
|---|---|---|
| `world.ptrg` | 国家（中国视角国界），含九段线 | Natural Earth 10m admin 0 (CHN worldview) |
| `admin1/<ISO3>.ptrg` | 一级行政区，裁剪到中国视角国界 | Natural Earth 10m admin 1；中日两国见下 |
| `admin1/JPN.ptrg`、`admin2/JPN.ptrg` | 都道府县、市区町村（东京 23 区与政令市各区合并） | 国土数値情報 N03（smartnews-smri 简化版） |
| `admin1/CHN.ptrg`、`admin2/CHN.ptrg` | 省级、地级市（直辖市、港澳台为叶子） | DataV.GeoAtlas |

香港、澳门、黄岩岛并入中国。区域 ID：国家为 ADM0_A3，日本 `JP-<代码>`，中国 `CN-<adcode>`，其余国家为 ISO 3166-2。

文件格式见 `build_regions.py` 中 `write_regions` 的说明，解码器为 `lib/footprint/region_data.dart`。数据来源与许可写在 `assets/footprint/LICENSE.txt`，并在应用的开源许可页显示。
