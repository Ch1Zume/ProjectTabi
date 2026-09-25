import 'package:flutter/foundation.dart';

/// Live capture is offered only by the mobile apps.
bool get supportsReferenceCamera => !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
     defaultTargetPlatform == TargetPlatform.iOS);
