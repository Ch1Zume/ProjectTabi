import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // CameraX output now keeps EXIF orientation instead of re-encoding pixels.
  // Record previews and comparison exports both use Flutter's image decoder.
  for (final orientation in [1, 6, 8]) {
    test('camera JPEG orientation $orientation displays upright', () async {
      final source = img.Image(width: 24, height: 12);
      source.exif.imageIfd.orientation = orientation;
      final bytes = Uint8List.fromList(img.encodeJpg(source, quality: 100));
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, orientation == 1 ? 24 : 12);
      expect(frame.image.height, orientation == 1 ? 12 : 24);
      frame.image.dispose();
      codec.dispose();
    });
  }
}
