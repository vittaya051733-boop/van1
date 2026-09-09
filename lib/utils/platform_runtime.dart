import 'dart:io';

import 'package:flutter/foundation.dart';

bool get isIosSimulator {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
    return false;
  }
  return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
}
