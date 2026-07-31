import 'package:flutter/foundation.dart';

/// Process-wide motion preference used by reusable widgets that own animation
/// controllers. The theme controller is the single writer; widgets may listen
/// without depending on Riverpod or duplicating preference storage.
class TorChatMotionPolicy {
  TorChatMotionPolicy._();

  static final ValueNotifier<bool> reducedMotion = ValueNotifier<bool>(false);

  static bool get enabled => reducedMotion.value;

  static void setEnabled(bool value) {
    if (reducedMotion.value == value) return;
    reducedMotion.value = value;
  }

  static Duration duration(Duration normal) =>
      enabled ? Duration.zero : normal;
}
