import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';
import 'country_colors.dart';
import 'footprint_data.dart';
import 'region_data.dart';

const double _degrees = math.pi / 180;
const double _minZoom = 0.8;
const double _maxZoom = 14;

/// Zoom at which the country under the view center becomes focused.
const double _focusZoom = 2.2;

/// View state of the globe, kept by the parent so it survives switching to
/// the 2D maps and back.
class GlobeCamera {
  GlobeCamera({this.lon = 120, this.lat = 28, this.zoom = 1});

  /// View center in degrees.
  double lon;
  double lat;
  double zoom;

  /// Whether the idle auto rotation is still running.
  bool spinning = true;

  GlobeCamera copy() => GlobeCamera(lon: lon, lat: lat, zoom: zoom)
    ..spinning = spinning;

  void restore(GlobeCamera other) {
    lon = other.lon;
    lat = other.lat;
    zoom = other.zoom;
    spinning = other.spinning;
  }
}

class GlobeView extends StatefulWidget {
  const GlobeView({
    required this.index,
    required this.camera,
    required this.onEnterCountry,
    super.key,
  });

  final FootprintIndex index;
  final GlobeCamera camera;
  final Future<void> Function(RegionFeature country) onEnterCountry;

  @override
  State<GlobeView> createState() => _GlobeViewState();
}

class _GlobeViewState extends State<GlobeView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late _GlobeGeometry _geometry = _GlobeGeometry(widget.index.world);
  final Map<String, TextPainter> _labelCache = {};

  Size _size = Size.zero;
  Duration _lastTick = Duration.zero;
  double _gestureStartZoom = 1;
  Offset _velocity = Offset.zero;
  _Flight? _flight;
  RegionFeature? _focused;

  /// Country picked by tapping; stays focused until the user moves the
  /// globe, even when it is framed below the focus zoom.
  RegionFeature? _selected;
  bool _entering = false;

  GlobeCamera get _camera => widget.camera;

  @override
  void initState() {
    super.initState();
    _updateFocus();
    _ensureTicking();
  }

  @override
  void didUpdateWidget(GlobeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.index.world, widget.index.world)) {
      _geometry = _GlobeGeometry(widget.index.world);
    }
    if (!identical(oldWidget.index, widget.index)) {
      _clearLabels();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clearLabels();
    super.dispose();
  }

  void _clearLabels() {
    for (final painter in _labelCache.values) {
      painter.dispose();
    }
    _labelCache.clear();
  }

  double get _baseRadius => math.min(_size.width, _size.height) * 0.4;

  double get _radius => _baseRadius * _camera.zoom;

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    var active = false;

    final flight = _flight;
    if (flight != null) {
      flight.elapsed += dt;
      final t = Curves.easeInOutCubic.transform(
        (flight.elapsed / flight.duration).clamp(0.0, 1.0),
      );
      _camera
        ..lon = _wrapLon(flight.fromLon + flight.deltaLon * t)
        ..lat = flight.fromLat + (flight.toLat - flight.fromLat) * t
        ..zoom = flight.fromZoom * math.pow(flight.toZoom / flight.fromZoom, t);
      if (flight.elapsed >= flight.duration) {
        _flight = null;
        flight.onDone?.call();
      }
      active = true;
    } else if (_velocity.distanceSquared > 1) {
      _panBy(_velocity * dt);
      final decay = math.exp(-dt * 3.2);
      _velocity = _velocity * decay;
      active = true;
    } else if (_camera.spinning) {
      _camera.lon = _wrapLon(_camera.lon + dt * 5);
      active = true;
    }

    if (active) {
      _updateFocus();
      setState(() {});
    } else {
      _ticker.stop();
    }
  }

  void _panBy(Offset pixels) {
    final radius = _radius;
    if (radius <= 0) {
      return;
    }
    _camera
      ..lon = _wrapLon(_camera.lon - pixels.dx / radius / _degrees)
      ..lat = (_camera.lat + pixels.dy / radius / _degrees).clamp(-85.0, 85.0);
  }

  void _stopMotion() {
    _camera.spinning = false;
    _velocity = Offset.zero;
    _flight = null;
  }

  void _updateFocus() {
    if (_selected != null) {
      _focused = _selected;
      return;
    }
    final focused = _camera.zoom >= _focusZoom
        ? widget.index.world.locate(_camera.lon, _camera.lat, tolerance: 1.5)
        : null;
    if (focused?.id != _focused?.id) {
      _focused = focused;
    }
  }

  void _setZoom(double zoom) {
    _camera.zoom = zoom.clamp(_minZoom, _maxZoom);
    _updateFocus();
  }

  void _flyTo({
    required double lon,
    required double lat,
    required double zoom,
    double duration = 0.7,
    VoidCallback? onDone,
  }) {
    _stopMotion();
    var deltaLon = _wrapLon(lon - _camera.lon);
    if (deltaLon > 180) {
      deltaLon -= 360;
    }
    _flight = _Flight(
      fromLon: _camera.lon,
      fromLat: _camera.lat,
      fromZoom: _camera.zoom,
      deltaLon: deltaLon,
      toLat: lat.clamp(-85.0, 85.0),
      toZoom: zoom.clamp(_minZoom, _maxZoom * 1.8),
      duration: duration,
      onDone: onDone,
    );
    _ensureTicking();
  }

  void _focusCountry(RegionFeature country) {
    final shape = _geometry.shapeOf(country.id);
    _flyTo(
      lon: country.label.longitude,
      lat: country.label.latitude,
      zoom: shape == null ? 4 : _fitZoom(shape.angularRadius),
    );
  }

  double _fitZoom(double angularRadius) {
    final sine = math.sin(angularRadius.clamp(0.02, math.pi / 2));
    return (1.05 / sine).clamp(1.2, _maxZoom);
  }

  void _enter(RegionFeature country) {
    if (_entering) {
      return;
    }
    final saved = _camera.copy()..spinning = false;
    final shape = _geometry.shapeOf(country.id);
    final fitted = shape == null ? 4.0 : _fitZoom(shape.angularRadius);
    setState(() => _entering = true);
    _flyTo(
      lon: country.label.longitude,
      lat: country.label.latitude,
      zoom: math.max(fitted, _camera.zoom) * 1.7,
      duration: 0.45,
      onDone: () async {
        // Return to the framed country when the user comes back.
        _camera.restore(saved);
        _camera
          ..lon = country.label.longitude
          ..lat = country.label.latitude
          ..zoom = math.max(fitted, saved.zoom);
        await widget.onEnterCountry(country);
        if (mounted) {
          setState(() => _entering = false);
        }
      },
    );
  }

  ({double lon, double lat})? _unproject(Offset position) {
    final radius = _radius;
    final x = (position.dx - _size.width / 2) / radius;
    final y = (_size.height / 2 - position.dy) / radius;
    final r2 = x * x + y * y;
    if (r2 > 1) {
      return null;
    }
    final z = math.sqrt(1 - r2);
    final rotation = _Rotation(_camera.lon, _camera.lat);
    final vx = x * rotation.xx + y * rotation.yx + z * rotation.zx;
    final vy = x * rotation.xy + y * rotation.yy + z * rotation.zy;
    final vz = y * rotation.yz + z * rotation.zz;
    return (
      lon: math.atan2(vy, vx) / _degrees,
      lat: math.asin(vz.clamp(-1.0, 1.0)) / _degrees,
    );
  }

  void _handleTap(TapUpDetails details) {
    final location = _unproject(details.localPosition);
    if (location == null) {
      return;
    }
    final country = widget.index.world.locate(
      location.lon,
      location.lat,
      tolerance: 0.4,
    );
    if (country == null) {
      return;
    }
    if (_focused?.id == country.id) {
      _enter(country);
    } else {
      setState(() => _focused = _selected = country);
      _focusCountry(country);
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _stopMotion();
      _selected = null;
      setState(() {
        _setZoom(_camera.zoom * math.exp(-event.scrollDelta.dy / 400));
      });
    }
  }

  void _zoomBy(double factor) {
    _flyTo(
      lon: _camera.lon,
      lat: _camera.lat,
      zoom: (_camera.zoom * factor).clamp(_minZoom, _maxZoom),
      duration: 0.3,
    );
  }

  void _reset() {
    _selected = null;
    _flyTo(lon: _camera.lon, lat: _camera.lat, zoom: 1, duration: 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focused;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerSignal: _handlePointerSignal,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTap,
                  onScaleStart: (details) {
                    _stopMotion();
                    _selected = null;
                    _gestureStartZoom = _camera.zoom;
                  },
                  onScaleUpdate: (details) {
                    setState(() {
                      _panBy(details.focalPointDelta);
                      if (details.pointerCount > 1 || details.scale != 1) {
                        _setZoom(_gestureStartZoom * details.scale);
                      } else {
                        _updateFocus();
                      }
                    });
                  },
                  onScaleEnd: (details) {
                    if (details.pointerCount == 0) {
                      final velocity = details.velocity.pixelsPerSecond;
                      final speed = velocity.distance;
                      _velocity = speed > 2400
                          ? velocity * (2400 / speed)
                          : velocity;
                      _ensureTicking();
                    }
                  },
                  child: AnimatedOpacity(
                    opacity: _entering ? 0 : 1,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeIn,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _GlobePainter(
                        geometry: _geometry,
                        index: widget.index,
                        lon: _camera.lon,
                        lat: _camera.lat,
                        zoom: _camera.zoom,
                        focusedId: focused?.id,
                        palette: _GlobePalette.current(),
                        labelCache: _labelCache,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: _GlobeControls(
                onZoomIn: () => _zoomBy(1.6),
                onZoomOut: () => _zoomBy(1 / 1.6),
                onReset: _reset,
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: focused == null
                    ? const _GlobeHint(key: ValueKey('globe-hint'))
                    : _FocusedCountryCard(
                        key: ValueKey('globe-focus-${focused.id}'),
                        country: focused,
                        recordCount: widget.index.countFor(focused.id),
                        onEnter: () => _enter(focused),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

double _wrapLon(double lon) {
  var value = (lon + 180) % 360;
  if (value < 0) {
    value += 360;
  }
  return value - 180;
}

class _Flight {
  _Flight({
    required this.fromLon,
    required this.fromLat,
    required this.fromZoom,
    required this.deltaLon,
    required this.toLat,
    required this.toZoom,
    required this.duration,
    this.onDone,
  });

  final double fromLon;
  final double fromLat;
  final double fromZoom;
  final double deltaLon;
  final double toLat;
  final double toZoom;
  final double duration;
  final VoidCallback? onDone;
  double elapsed = 0;
}

/// Rotation from geographic unit vectors to view space for an orthographic
/// projection centered at (lon0, lat0): x east, y north, z toward viewer.
class _Rotation {
  _Rotation(double lon0, double lat0) {
    final lambda = lon0 * _degrees;
    final phi = lat0 * _degrees;
    final sl = math.sin(lambda);
    final cl = math.cos(lambda);
    final sp = math.sin(phi);
    final cp = math.cos(phi);
    xx = -sl;
    xy = cl;
    yx = -sp * cl;
    yy = -sp * sl;
    yz = cp;
    zx = cp * cl;
    zy = cp * sl;
    zz = sp;
  }

  late final double xx, xy;
  late final double yx, yy, yz;
  late final double zx, zy, zz;
}

// ------------------------------------------------------------- geometry --

class _GlobeRing {
  _GlobeRing(this.xyz, this.strokeEdge);

  /// Unit vectors, three floats per vertex.
  final Float32List xyz;

  /// Whether the edge ending at each vertex is a real border. Antimeridian
  /// seams and south-pole closures are filled but not stroked.
  final Uint8List strokeEdge;

  int get length => xyz.length ~/ 3;
}

class _GlobeShape {
  _GlobeShape({
    required this.polygons,
    required this.center,
    required this.angularRadius,
  });

  /// Rings per polygon; the first ring of each polygon is the exterior.
  final List<List<_GlobeRing>> polygons;
  final Float32List center;
  final double angularRadius;
}

class _GlobeGeometry {
  _GlobeGeometry(RegionSet world) {
    for (final feature in world.features) {
      _shapes[feature.id] = _shapeOf(feature);
    }
    lines = [for (final line in world.lines) _ringOf(line, closed: false)];
    graticule = [
      for (var lon = -180; lon < 180; lon += 30)
        _sampled([for (var lat = -90; lat <= 90; lat += 3) (lon, lat)]),
      for (var lat = -60; lat <= 60; lat += 30)
        _sampled([for (var lon = -180; lon <= 180; lon += 3) (lon, lat)]),
    ];
    var longest = 0;
    for (final shape in _shapes.values) {
      for (final rings in shape.polygons) {
        for (final ring in rings) {
          longest = math.max(longest, ring.length);
        }
      }
    }
    scratch = Float32List(math.max(longest, 400) * 3);
  }

  final Map<String, _GlobeShape> _shapes = {};
  late final List<_GlobeRing> lines;
  late final List<_GlobeRing> graticule;
  late final Float32List scratch;

  Iterable<MapEntry<String, _GlobeShape>> get entries => _shapes.entries;

  _GlobeShape? shapeOf(String id) => _shapes[id];

  static _GlobeShape _shapeOf(RegionFeature feature) {
    final polygons = [
      for (final polygon in feature.polygons)
        [for (final ring in polygon.rings) _ringOf(ring)],
    ];
    final center = _unitVector(feature.label.longitude, feature.label.latitude);
    var maxAngle = 0.0;
    for (final rings in polygons) {
      final xyz = rings.first.xyz;
      for (var i = 0; i < xyz.length; i += 3) {
        final dot =
            xyz[i] * center[0] + xyz[i + 1] * center[1] + xyz[i + 2] * center[2];
        maxAngle = math.max(maxAngle, math.acos(dot.clamp(-1.0, 1.0)));
      }
    }
    return _GlobeShape(
      polygons: polygons,
      center: center,
      angularRadius: maxAngle,
    );
  }

  static _GlobeRing _ringOf(RegionRing ring, {bool closed = true}) {
    final count = ring.length;
    final xyz = Float32List(count * 3);
    final stroke = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final lon = ring.lonAt(i);
      final lat = ring.latAt(i);
      final v = _unitVector(lon, lat);
      xyz[i * 3] = v[0];
      xyz[i * 3 + 1] = v[1];
      xyz[i * 3 + 2] = v[2];
      final previous = i == 0 ? (closed ? count - 1 : -1) : i - 1;
      if (previous < 0) {
        continue;
      }
      final prevLon = ring.lonAt(previous);
      final prevLat = ring.latAt(previous);
      final seam = lon.abs() > 179.99 && prevLon.abs() > 179.99;
      final pole = lat < -89.9 || prevLat < -89.9;
      stroke[i] = seam || pole ? 0 : 1;
    }
    return _GlobeRing(xyz, stroke);
  }

  static _GlobeRing _sampled(List<(int, int)> points) {
    final xyz = Float32List(points.length * 3);
    final stroke = Uint8List(points.length);
    for (var i = 0; i < points.length; i++) {
      final v = _unitVector(points[i].$1.toDouble(), points[i].$2.toDouble());
      xyz.setRange(i * 3, i * 3 + 3, v);
      stroke[i] = i == 0 ? 0 : 1;
    }
    return _GlobeRing(xyz, stroke);
  }
}

Float32List _unitVector(double lon, double lat) {
  final lambda = lon * _degrees;
  final phi = lat * _degrees;
  final cp = math.cos(phi);
  return Float32List.fromList([
    cp * math.cos(lambda),
    cp * math.sin(lambda),
    math.sin(phi),
  ]);
}

// -------------------------------------------------------------- painting --

class _GlobePalette {
  const _GlobePalette({
    required this.background,
    required this.sphere,
    required this.glow,
    required this.limb,
    required this.border,
    required this.backBorder,
    required this.graticule,
    required this.focus,
    required this.label,
    required this.labelBackground,
  });

  factory _GlobePalette.current() {
    final dark = AppColors.isDark;
    return _GlobePalette(
      background: AppColors.background,
      sphere: dark ? const Color(0xFF1E2A38) : const Color(0xFFE4EEF8),
      glow: AppColors.accent,
      limb: AppColors.textSecondary.withValues(alpha: dark ? 0.45 : 0.35),
      border: AppColors.textPrimary.withValues(alpha: dark ? 0.42 : 0.38),
      backBorder: AppColors.textSecondary.withValues(alpha: dark ? 0.16 : 0.13),
      graticule: AppColors.textSecondary.withValues(alpha: 0.08),
      focus: AppColors.accentDark,
      label: AppColors.textPrimary,
      labelBackground: AppColors.surface.withValues(alpha: 0.86),
    );
  }

  final Color background;
  final Color sphere;
  final Color glow;
  final Color limb;
  final Color border;
  final Color backBorder;
  final Color graticule;
  final Color focus;
  final Color label;
  final Color labelBackground;
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.geometry,
    required this.index,
    required this.lon,
    required this.lat,
    required this.zoom,
    required this.focusedId,
    required this.palette,
    required this.labelCache,
  });

  final _GlobeGeometry geometry;
  final FootprintIndex index;
  final double lon;
  final double lat;
  final double zoom;
  final String? focusedId;
  final _GlobePalette palette;
  final Map<String, TextPainter> labelCache;

  late _Rotation _rotation;
  late double _cx;
  late double _cy;
  late double _radius;

  @override
  void paint(Canvas canvas, Size size) {
    _rotation = _Rotation(lon, lat);
    _cx = size.width / 2;
    _cy = size.height / 2;
    _radius = math.min(size.width, size.height) * 0.4 * zoom;
    final center = Offset(_cx, _cy);
    canvas.clipRect(Offset.zero & size);

    // Atmosphere and translucent sphere body.
    canvas.drawCircle(
      center,
      _radius * 1.12,
      Paint()
        ..shader = RadialGradient(
          colors: [
            palette.glow.withValues(alpha: 0.16),
            palette.glow.withValues(alpha: 0),
          ],
          stops: const [0.89, 1],
        ).createShader(Rect.fromCircle(center: center, radius: _radius * 1.12)),
    );
    canvas.drawCircle(
      center,
      _radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.1,
          colors: [
            palette.sphere.withValues(alpha: 0.55),
            palette.sphere.withValues(alpha: 0.18),
            palette.background.withValues(alpha: 0.05),
          ],
          stops: const [0, 0.7, 1],
        ).createShader(Rect.fromCircle(center: center, radius: _radius)),
    );

    final strokeWidth = (0.6 + zoom * 0.08).clamp(0.6, 1.4);

    // Far side borders show through the transparent globe.
    final back = Path();
    for (final entry in geometry.entries) {
      for (final rings in entry.value.polygons) {
        for (final ring in rings) {
          _addStroke(back, ring, front: false);
        }
      }
    }
    canvas.drawPath(
      back,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.8
        ..color = palette.backBorder,
    );

    final graticule = Path();
    for (final ring in geometry.graticule) {
      _addStroke(graticule, ring, front: true);
    }
    canvas.drawPath(
      graticule,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = palette.graticule,
    );

    // Visited countries in their representative color.
    for (final country in index.visitedCountries) {
      final shape = geometry.shapeOf(country.id);
      if (shape == null || !_maybeVisible(shape)) {
        continue;
      }
      final fill = Path()..fillType = PathFillType.evenOdd;
      for (final rings in shape.polygons) {
        for (var r = 0; r < rings.length; r++) {
          _addClippedFill(fill, rings[r], hole: r > 0);
        }
      }
      canvas.drawPath(
        fill,
        Paint()..color = countryColor(country.id).withValues(alpha: 0.82),
      );
    }

    final front = Path();
    for (final entry in geometry.entries) {
      if (!_maybeVisible(entry.value)) {
        continue;
      }
      for (final rings in entry.value.polygons) {
        for (final ring in rings) {
          _addStroke(front, ring, front: true);
        }
      }
    }
    for (final line in geometry.lines) {
      _addStroke(front, line, front: true);
    }
    canvas.drawPath(
      front,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..color = palette.border,
    );

    final focused = focusedId == null ? null : geometry.shapeOf(focusedId!);
    if (focused != null && _maybeVisible(focused)) {
      final outline = Path()..fillType = PathFillType.evenOdd;
      for (final rings in focused.polygons) {
        for (var r = 0; r < rings.length; r++) {
          _addClippedFill(outline, rings[r], hole: r > 0);
        }
      }
      if (!index.isVisited(focusedId!)) {
        canvas.drawPath(
          outline,
          Paint()..color = palette.focus.withValues(alpha: 0.12),
        );
      }
      final focusStroke = Path();
      for (final rings in focused.polygons) {
        for (final ring in rings) {
          _addStroke(focusStroke, ring, front: true);
        }
      }
      canvas.drawPath(
        focusStroke,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..color = palette.focus,
      );
    }

    canvas.drawCircle(
      center,
      _radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = palette.limb,
    );

    _paintLabels(canvas, size);
  }

  bool _maybeVisible(_GlobeShape shape) {
    final c = shape.center;
    final z = c[0] * _rotation.zx + c[1] * _rotation.zy + c[2] * _rotation.zz;
    return z > -math.sin(math.min(shape.angularRadius, math.pi / 2)) - 0.02;
  }

  /// Projects ring vertices into [geometry.scratch] as view-space x, y, z.
  void _project(_GlobeRing ring) {
    final xyz = ring.xyz;
    final out = geometry.scratch;
    final r = _rotation;
    for (var i = 0; i < xyz.length; i += 3) {
      final vx = xyz[i];
      final vy = xyz[i + 1];
      final vz = xyz[i + 2];
      out[i] = vx * r.xx + vy * r.xy;
      out[i + 1] = vx * r.yx + vy * r.yy + vz * r.yz;
      out[i + 2] = vx * r.zx + vy * r.zy + vz * r.zz;
    }
  }

  double _sx(double x) => _cx + x * _radius;

  double _sy(double y) => _cy - y * _radius;

  /// Strokes the edges of [ring] on the near ([front]) or far side.
  void _addStroke(Path path, _GlobeRing ring, {required bool front}) {
    _project(ring);
    final p = geometry.scratch;
    final count = ring.length;
    var penDown = false;
    // Edge n ends at vertex n % count; edge 0 (last -> first) comes last.
    for (var n = 1; n <= count; n++) {
      final i = n % count;
      final j = n - 1;
      if (ring.strokeEdge[i] == 0) {
        penDown = false;
        continue;
      }
      final zi = p[i * 3 + 2];
      final zj = p[j * 3 + 2];
      final visibleI = front ? zi >= 0 : zi < 0;
      final visibleJ = front ? zj >= 0 : zj < 0;
      if (!visibleI && !visibleJ) {
        penDown = false;
        continue;
      }
      double ax = p[j * 3], ay = p[j * 3 + 1];
      double bx = p[i * 3], by = p[i * 3 + 1];
      if (visibleI != visibleJ) {
        final t = zj / (zj - zi);
        var hx = ax + (bx - ax) * t;
        var hy = ay + (by - ay) * t;
        final length = math.sqrt(hx * hx + hy * hy);
        if (length > 0) {
          hx /= length;
          hy /= length;
        }
        if (visibleJ) {
          bx = hx;
          by = hy;
        } else {
          ax = hx;
          ay = hy;
          penDown = false;
        }
      }
      if (!penDown) {
        path.moveTo(_sx(ax), _sy(ay));
        penDown = true;
      }
      path.lineTo(_sx(bx), _sy(by));
      if (!visibleI) {
        penDown = false;
      }
    }
  }

  /// Adds the visible part of a ring as a closed contour, following the
  /// horizon between the points where the ring leaves and re-enters view.
  void _addClippedFill(Path path, _GlobeRing ring, {required bool hole}) {
    _project(ring);
    final p = geometry.scratch;
    final count = ring.length;
    var start = -1;
    for (var i = 0; i < count; i++) {
      if (p[i * 3 + 2] >= 0) {
        start = i;
        break;
      }
    }
    if (start < 0 || count < 3) {
      return;
    }
    path.moveTo(_sx(p[start * 3]), _sy(p[start * 3 + 1]));
    var exitAngle = 0.0;
    var previous = start;
    for (var n = 1; n <= count; n++) {
      final i = (start + n) % count;
      final zi = p[i * 3 + 2];
      final zj = p[previous * 3 + 2];
      final visibleI = zi >= 0;
      final visibleJ = zj >= 0;
      if (visibleI != visibleJ) {
        final t = zj / (zj - zi);
        final hx = p[previous * 3] + (p[i * 3] - p[previous * 3]) * t;
        final hy = p[previous * 3 + 1] + (p[i * 3 + 1] - p[previous * 3 + 1]) * t;
        final angle = math.atan2(hy, hx);
        if (visibleJ) {
          exitAngle = angle;
          path.lineTo(_sx(math.cos(angle)), _sy(math.sin(angle)));
        } else {
          _addLimbArc(path, exitAngle, angle, counterClockwise: !hole);
        }
      }
      if (visibleI) {
        path.lineTo(_sx(p[i * 3]), _sy(p[i * 3 + 1]));
      }
      previous = i;
    }
    path.close();
  }

  void _addLimbArc(
    Path path,
    double from,
    double to, {
    required bool counterClockwise,
  }) {
    var sweep = to - from;
    if (counterClockwise) {
      while (sweep < 0) {
        sweep += math.pi * 2;
      }
    } else {
      while (sweep > 0) {
        sweep -= math.pi * 2;
      }
    }
    final steps = math.max(1, (sweep.abs() / (4 * _degrees)).ceil());
    for (var s = 1; s <= steps; s++) {
      final angle = from + sweep * s / steps;
      path.lineTo(_sx(math.cos(angle)), _sy(math.sin(angle)));
    }
  }

  void _paintLabels(Canvas canvas, Size size) {
    final ids = <String>{
      for (final country in index.visitedCountries) country.id,
      ?focusedId,
    };
    for (final id in ids) {
      final country = index.world[id];
      if (country == null) {
        continue;
      }
      final v = _unitVector(country.label.longitude, country.label.latitude);
      final r = _rotation;
      final z = v[0] * r.zx + v[1] * r.zy + v[2] * r.zz;
      if (z < 0.2) {
        continue;
      }
      final x = v[0] * r.xx + v[1] * r.xy;
      final y = v[0] * r.yx + v[1] * r.yy + v[2] * r.yz;
      final count = index.countFor(id);
      final text = count > 0 ? '${country.name} $count' : country.name;
      final focused = id == focusedId;
      final key = '$id|$text|$focused|${palette.label.toARGB32()}';
      final painter = labelCache.putIfAbsent(
        key,
        () => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: palette.label,
              fontSize: focused ? 13 : 11,
              fontWeight: focused ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(),
      );
      final anchor = Offset(_sx(x), _sy(y));
      final box = Rect.fromCenter(
        center: anchor,
        width: painter.width + 12,
        height: painter.height + 4,
      );
      if (!(Offset.zero & size).overlaps(box)) {
        continue;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(8)),
        Paint()..color = palette.labelBackground.withValues(alpha: z.clamp(0.2, 0.86)),
      );
      painter.paint(
        canvas,
        anchor - Offset(painter.width / 2, painter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) =>
      oldDelegate.lon != lon ||
      oldDelegate.lat != lat ||
      oldDelegate.zoom != zoom ||
      oldDelegate.focusedId != focusedId ||
      !identical(oldDelegate.index, index) ||
      oldDelegate.palette.border != palette.border;
}

// ------------------------------------------------------------ overlays --

class _GlobeControls extends StatelessWidget {
  const _GlobeControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface.withValues(alpha: 0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '放大',
            onPressed: onZoomIn,
            icon: const Icon(LucideIcons.plus, size: 20),
          ),
          IconButton(
            tooltip: '缩小',
            onPressed: onZoomOut,
            icon: const Icon(LucideIcons.minus, size: 20),
          ),
          IconButton(
            tooltip: '查看整个地球',
            onPressed: onReset,
            icon: const Icon(LucideIcons.globe, size: 20),
          ),
        ],
      ),
    );
  }
}

class _GlobeHint extends StatelessWidget {
  const _GlobeHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            '拖动旋转 · 缩放或点击国家聚焦',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _FocusedCountryCard extends StatelessWidget {
  const _FocusedCountryCard({
    required this.country,
    required this.recordCount,
    required this.onEnter,
    super.key,
  });

  final RegionFeature country;
  final int recordCount;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final color = countryColor(country.id);
    return Material(
      color: AppColors.surface,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onEnter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: recordCount > 0 ? color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      country.name,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      recordCount > 0 ? '$recordCount 条巡礼记录' : '尚未留下足迹',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: onEnter,
                icon: const Icon(LucideIcons.chevronRight, size: 18),
                iconAlignment: IconAlignment.end,
                label: const Text('进入'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
