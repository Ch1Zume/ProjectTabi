import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import 'region_data.dart';

/// A region painted with a photo clipped to its outline.
class RegionPhotoFill {
  const RegionPhotoFill({required this.region, required this.image});

  final RegionFeature region;
  final ui.Image image;
}

/// Map layer drawing each region's representative photo inside its shape,
/// in the style of a photo-collage travel map.
class RegionPhotoLayer extends StatelessWidget {
  const RegionPhotoLayer({
    required this.fills,
    required this.borderColor,
    super.key,
  });

  final List<RegionPhotoFill> fills;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RegionPhotoPainter(
          fills: fills,
          camera: camera,
          borderColor: borderColor,
        ),
      ),
    );
  }
}

class _RegionPhotoPainter extends CustomPainter {
  _RegionPhotoPainter({
    required this.fills,
    required this.camera,
    required this.borderColor,
  });

  final List<RegionPhotoFill> fills;
  final MapCamera camera;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    final imagePaint = Paint()..filterQuality = FilterQuality.medium;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..color = borderColor;
    for (final fill in fills) {
      final path = _pathOf(fill.region);
      final bounds = path.getBounds();
      if (bounds.isEmpty || !bounds.overlaps(screen)) {
        continue;
      }
      // Photos fill the main landmass; far islands show crops of the edge.
      final main = _rectOf(fill.region.mainBounds);
      final target = main.isEmpty ? bounds : main;
      canvas
        ..save()
        ..clipPath(path);
      final image = fill.image;
      final source = _coverSource(
        Size(image.width.toDouble(), image.height.toDouble()),
        target.size,
      );
      canvas
        ..drawImageRect(image, source, target, imagePaint)
        ..restore()
        ..drawPath(path, border);
    }
  }

  Path _pathOf(RegionFeature region) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final polygon in region.polygons) {
      for (final ring in polygon.rings) {
        if (ring.length < 3) {
          continue;
        }
        final points = <Offset>[
          for (var i = 0; i < ring.length; i++)
            camera.latLngToScreenOffset(LatLng(ring.latAt(i), ring.lonAt(i))),
        ];
        path.addPolygon(points, true);
      }
    }
    return path;
  }

  Rect _rectOf(RegionBounds bounds) => Rect.fromPoints(
    camera.latLngToScreenOffset(LatLng(bounds.north, bounds.west)),
    camera.latLngToScreenOffset(LatLng(bounds.south, bounds.east)),
  );

  /// Centered source rectangle that covers [target] without distortion.
  static Rect _coverSource(Size image, Size target) {
    if (target.width <= 0 || target.height <= 0) {
      return Offset.zero & image;
    }
    final scale = (image.width / target.width) < (image.height / target.height)
        ? image.width / target.width
        : image.height / target.height;
    final width = target.width * scale;
    final height = target.height * scale;
    return Rect.fromLTWH(
      (image.width - width) / 2,
      (image.height - height) / 2,
      width,
      height,
    );
  }

  @override
  bool shouldRepaint(_RegionPhotoPainter oldDelegate) =>
      !identical(oldDelegate.fills, fills) ||
      oldDelegate.camera != camera ||
      oldDelegate.borderColor != borderColor;
}
