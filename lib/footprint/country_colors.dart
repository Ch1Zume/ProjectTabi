import 'package:flutter/painting.dart';

/// Representative colors keyed by Natural Earth ADM0_A3 codes, loosely based
/// on each country's flag or common association and tuned to read well as a
/// translucent map fill.
const Map<String, Color> _countryColors = {
  'CHN': Color(0xFFE53935), // 中国红
  'JPN': Color(0xFFF4A6C1), // 樱粉
  'KOR': Color(0xFF3F7FD9),
  'PRK': Color(0xFFC62828),
  'MNG': Color(0xFF2B6CB0),
  'VNM': Color(0xFFD84B3A),
  'THA': Color(0xFF3949AB),
  'SGP': Color(0xFFEF5350),
  'MYS': Color(0xFF1E5AA8),
  'IDN': Color(0xFFE5534B),
  'PHL': Color(0xFF2E6FD8),
  'KHM': Color(0xFF2846A8),
  'LAO': Color(0xFF2F58B8),
  'MMR': Color(0xFFF2B935),
  'IND': Color(0xFFF59C3C),
  'NPL': Color(0xFFC0392B),
  'LKA': Color(0xFFF0A93B),
  'BGD': Color(0xFF138A5E),
  'PAK': Color(0xFF1B7A43),
  'KAZ': Color(0xFF34A8D8),
  'UZB': Color(0xFF3AA6C9),
  'ARE': Color(0xFF2E8B57),
  'SAU': Color(0xFF1B7F4B),
  'TUR': Color(0xFFE23D3D),
  'ISR': Color(0xFF3E78D6),
  'EGY': Color(0xFFD9A441),
  'RUS': Color(0xFF4A6FC1),
  'GBR': Color(0xFF2D4A9A),
  'IRL': Color(0xFF2FAF6A),
  'FRA': Color(0xFF3567C9),
  'DEU': Color(0xFFF2C230),
  'ITA': Color(0xFF2E9E5B),
  'ESP': Color(0xFFF3B23A),
  'PRT': Color(0xFF2E8B57),
  'NLD': Color(0xFFF08A2C),
  'BEL': Color(0xFFF1C232),
  'CHE': Color(0xFFE53935),
  'AUT': Color(0xFFD94848),
  'CZE': Color(0xFF3B6BC4),
  'POL': Color(0xFFE85C6A),
  'HUN': Color(0xFF3B8E5A),
  'GRC': Color(0xFF3D8FD6),
  'SWE': Color(0xFF2F7BD0),
  'NOR': Color(0xFFD9473F),
  'DNK': Color(0xFFD93A3A),
  'FIN': Color(0xFF3A6FD0),
  'ISL': Color(0xFF3B5FB8),
  'UKR': Color(0xFFF2C94C),
  'USA': Color(0xFF3B5BA9),
  'CAN': Color(0xFFE04444),
  'MEX': Color(0xFF2E8B57),
  'BRA': Color(0xFF34A853),
  'ARG': Color(0xFF6CB4E8),
  'CHL': Color(0xFFD9473F),
  'PER': Color(0xFFD94848),
  'CUB': Color(0xFF3060B8),
  'AUS': Color(0xFFF2B33D),
  'NZL': Color(0xFF2A3F8F),
  'ZAF': Color(0xFF2E8B57),
  'KEN': Color(0xFF2B8A3E),
  'MAR': Color(0xFFC0392B),
};

const List<Color> _fallbackPalette = [
  Color(0xFF5B8DEF),
  Color(0xFF3FB68B),
  Color(0xFFF2A541),
  Color(0xFFE5677A),
  Color(0xFF9B7BE0),
  Color(0xFF3DB7C4),
  Color(0xFFE08A4F),
  Color(0xFF7FB346),
];

Color countryColor(String countryCode) {
  final color = _countryColors[countryCode];
  if (color != null) {
    return color;
  }
  var hash = 0;
  for (final unit in countryCode.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _fallbackPalette[hash % _fallbackPalette.length];
}
