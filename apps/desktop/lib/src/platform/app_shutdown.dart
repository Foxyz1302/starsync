import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../files/thumbnails.dart';
import '../state/session_state.dart';

// The one way out of the app (close button, Alt+F4, Update and restart).
// Order matters: every mpv player goes before the engine does (a live one
// calls a dead Dart callback), then the network goodbye, then the window
// closes through the platform's normal path so the engine is torn down
// inside the message loop. The runners end the process right after
// (`linux/runner/main.cc`, `windows/runner/main.cpp`).

bool _shuttingDown = false;

/// True once [shutDownApp] started.
bool get shuttingDown => _shuttingDown;

/// Hides the window, releases every player and the sound device, leaves
/// (others see "left", a hosted server stops), runs [beforeQuit], then
/// closes the window. Every step is bounded; a second call does nothing.
Future<void> shutDownApp({Future<void> Function()? beforeQuit}) async {
  if (_shuttingDown) return;
  _shuttingDown = true;
  final session = SessionState.instance;
  final shell = session.ports.shell;
  final total = Stopwatch()..start();
  await _step('window save', shell.saveWindow(), const Duration(milliseconds: 500));
  await _step('hide', shell.hide(), const Duration(milliseconds: 500));
  await Future.wait([
    _step('players', session.coordinator.releasePlayers(), const Duration(seconds: 3)),
    _step('thumbnails', cancelAllThumbnails(), const Duration(milliseconds: 1500)),
    _step('sounds', session.sfx.dispose(), const Duration(milliseconds: 500)),
  ]);
  // Windows: media_kit_video frees a player's video output on a thread of
  // its own after dispose returns; it must be done before the engine
  // stops, or the plugin's teardown waits on it for good.
  if (Platform.isWindows) await Future.delayed(const Duration(milliseconds: 300));
  // Jellyfin stop report, last diagnostics, the goodbye, then the hosted
  // server: 3 s in all.
  await _step('leave', session.leave(), const Duration(milliseconds: 2500));
  await _step('server stop', session.stopServer(), const Duration(milliseconds: 500));
  if (beforeQuit != null) await _step('before quit', beforeQuit(), const Duration(seconds: 3));
  debugPrint('close: ready to quit after ${total.elapsedMilliseconds} ms');
  await shell.quit();
  // The engine stops with the window, so this only fires when the close
  // did not go through. A kill, not exit(): no exit handlers (NVIDIA's
  // EGL one segfaults, Windows DLL detach can hang).
  Timer(const Duration(seconds: 3), () {
    debugPrint('close: the window did not close; ending the process');
    Process.killPid(pid, ProcessSignal.sigkill);
  });
}

Future<void> _step(String what, Future<void>? f, Duration limit) async {
  if (f == null) return;
  final sw = Stopwatch()..start();
  try {
    await f.timeout(limit);
  } on TimeoutException {
    debugPrint('close: $what did not finish in ${limit.inMilliseconds} ms');
  } catch (e) {
    debugPrint('close: $what failed: $e');
  }
  if (sw.elapsedMilliseconds > 200) debugPrint('close: $what took ${sw.elapsedMilliseconds} ms');
}
