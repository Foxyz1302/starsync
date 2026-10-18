import 'dart:io';

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

/// The desktop's activation token this process started with (Linux:
/// `XDG_ACTIVATION_TOKEN` or `DESKTOP_STARTUP_ID`, kept by the runner
/// before GTK used it); '' when none or elsewhere.
Future<String> windowLaunchToken() async {
  if (!Platform.isLinux) return '';
  try {
    return await _window.invokeMethod<String>('launchToken') ?? '';
  } catch (_) {
    return '';
  }
}

/// Linux: brings the window up with another start's activation token
/// ([windowLaunchToken] of the start that handed over). False where the
/// runner lacks it.
Future<bool> presentWindow(String token) async {
  if (!Platform.isLinux) return false;
  try {
    await _window.invokeMethod<void>('present', token);
    return true;
  } catch (_) {
    return false;
  }
}

/// Ends this process at once with no exit handlers (a second start that
/// handed over; its window never showed). The runner does it; where it
/// cannot, a kill.
Future<Never> exitNow() async {
  try {
    await _window.invokeMethod<void>('exit');
  } catch (_) {}
  Process.killPid(pid, ProcessSignal.sigkill);
  // The kill lands before anything else runs.
  await Future<void>.delayed(const Duration(days: 1));
  throw StateError('unreachable');
}
