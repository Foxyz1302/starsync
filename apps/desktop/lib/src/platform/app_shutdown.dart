import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart' show DiagUploader;

import '../files/thumbnails.dart';
import '../app/app_graph.dart';
import 'crash_watch.dart';
import 'single_instance.dart';

// The one way out of the app (close button, Alt+F4, Update and restart).
// Order matters: every mpv player goes before the engine does (a live one
// calls a dead Dart callback), then the network goodbye, then the window
// closes through the platform's normal path so the engine is torn down
// inside the message loop. The runners end the process right after
// (`linux/runner/main.cc`, `windows/runner/main.cpp`).

bool _shuttingDown = false;

/// True once [shutDownApp] started.
bool get shuttingDown => _shuttingDown;

/// The systems the close stops; `main` hands them over once.
AppGraph? _graph;

/// This app's claim on its profile folder (one app at a time).
InstanceLock? _instance;

/// Makes [graph] the one [shutDownApp] stops (and [instance] the claim it
/// gives up) and returns the close request handler for the window.
Future<void> Function() closeAppWith(AppGraph graph, {InstanceLock? instance}) {
  _graph = graph;
  _instance = instance;
  return shutDownApp;
}

/// Hides the window, releases every player and the sound device, leaves
/// (the `bye` goes out first, so others see "left" at once; then your
/// server stops), runs [beforeQuit], then closes the window. [restart]
/// (Update and restart) leaves without the `bye`: the member stays
/// `gone`, and the restarted app, same client id, takes it back within
/// the grace. Every step is bounded; a second call does nothing.
Future<void> shutDownApp({Future<void> Function()? beforeQuit, bool restart = false}) async {
  final graph = _graph;
  if (_shuttingDown || graph == null) return;
  _shuttingDown = true;
  crashWatchClosing();
  DiagUploader.flushAllSoon();
  // Every step is bounded, but a timeout only stops waiting and the quit
  // itself is not: whatever stalls, the process ends.
  Timer(const Duration(seconds: 20), () {
    debugPrint('close: still running after 20 s; ending the process');
    Process.killPid(pid, ProcessSignal.sigkill);
  });
  // A start from now on waits for this app to end instead of handing its
  // link to it.
  _instance?.closing();
  final shell = graph.ports.shell;
  final total = Stopwatch()..start();
  await _step('window save', shell.saveWindow(), const Duration(milliseconds: 500));
  await _step('hide', shell.hide(), const Duration(milliseconds: 500));
  await Future.wait([
    _step('players', graph.coordinator.releasePlayers(), const Duration(seconds: 3)),
    _step('thumbnails', cancelAllThumbnails(), const Duration(milliseconds: 1500)),
    _step('sounds', graph.sfx.dispose(), const Duration(milliseconds: 500)),
  ]);
  // The host owns the disposal order: anything still alive goes now. A
  // player's dispose ends once its video output and mpv core are gone.
  await _step('all players', graph.ports.players.disposeAll(), const Duration(milliseconds: 1500));
  // Jellyfin stop report, last diagnostics, the bye (flushed), then your
  // server: 3 s in all.
  await _step('leave', graph.navigation.leave(bye: !restart), const Duration(milliseconds: 2500));
  await _step('server stop', graph.yourServer.stop(), const Duration(milliseconds: 500));
  // Update and restart: the new binary claims the folder at once.
  if (restart) await _step('instance', _instance?.release(), const Duration(milliseconds: 500));
  if (beforeQuit != null) await _step('before quit', beforeQuit(), const Duration(seconds: 3));
  debugPrint('close: ready to quit after ${total.elapsedMilliseconds} ms');
  crashWatchClean();
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
