import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The runner's window channel (linux/runner/my_application.cc,
/// windows/runner/flutter_window.cpp).
const _window = MethodChannel('starsync/window');

/// Asks the desktop to point at the app's window (taskbar flash, urgency
/// hint) when it is not focused; nothing when it is. The runner clears it
/// once the window gets focus. Quietly nothing where the runner lacks it.
Future<void> requestWindowAttention() async {
  try {
    await _window.invokeMethod<void>('attention');
  } on MissingPluginException {
    // Tests, other platforms.
  } catch (e) {
    debugPrint('window attention: $e');
  }
}
