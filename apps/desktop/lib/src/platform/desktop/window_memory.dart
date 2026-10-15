import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// The window's size, position and maximized state across restarts (and
/// hot restarts), in the settings box. The size and position kept are
/// the normal (unmaximized) ones; fullscreen is never saved or restored.
/// Wayland lets no app place its own window, so there only the size and
/// maximized state come back (the compositor decides the position).
class WindowMemory with WindowListener {
  static const _key = 'windowBounds';
  static const defaultSize = Size(1280, 720);

  // Null when the settings box failed to open: defaults, nothing saved.
  final Box? _box;
  Timer? _save;
  WindowMemory(this._box);

  static bool get _canPlace => !(Platform.isLinux && Platform.environment['WAYLAND_DISPLAY'] != null);

  Map? get _saved => _box?.get(_key) is Map ? _box!.get(_key) as Map : null;

  /// The size to open at: the last normal size, else [defaultSize].
  Size get size {
    final s = _saved;
    final w = s?['w'], h = s?['h'];
    return w is num && h is num && w >= 160 && h >= 90 ? Size(w.toDouble(), h.toDouble()) : defaultSize;
  }

  /// Whether a saved position exists to place the window at (else center).
  bool get hasPosition => _canPlace && _saved?['x'] is num && _saved?['y'] is num;

  /// After the window shows: back to the saved position when it still
  /// lands on a connected display, maximized when it was; then listens.
  Future<void> restore() async {
    final s = _saved;
    try {
      if (s != null && hasPosition) {
        final rect = Offset((s['x'] as num).toDouble(), (s['y'] as num).toDouble()) & size;
        if (await _onSomeDisplay(rect)) {
          await windowManager.setPosition(rect.topLeft);
        } else {
          await windowManager.center();
        }
      }
      if (s?['max'] == true) await windowManager.maximize();
    } catch (e) {
      debugPrint('window restore failed: $e');
    }
    windowManager.addListener(this);
  }

  // At least a 100×50 corner of the title area on a display's visible area.
  static Future<bool> _onSomeDisplay(Rect r) async {
    final grip = Rect.fromLTWH(r.left, r.top, r.width.clamp(0, 100).toDouble(), 50);
    for (final d in await screenRetriever.getAllDisplays()) {
      final area = (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
      if (area.overlaps(grip)) return true;
    }
    return false;
  }

  void _later() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () => unawaited(save()));
  }

  /// Writes the current state now (also on close).
  Future<void> save() async {
    _save?.cancel();
    final box = _box;
    if (box == null) return;
    try {
      if (await windowManager.isFullScreen() || await windowManager.isMinimized()) return;
      final max = await windowManager.isMaximized();
      final s = Map<String, Object?>.of((_saved ?? const {}).cast<String, Object?>());
      s['max'] = max;
      if (!max) {
        final b = await windowManager.getBounds();
        s['w'] = b.width;
        s['h'] = b.height;
        if (_canPlace) {
          s['x'] = b.left;
          s['y'] = b.top;
        }
      }
      await box.put(_key, s);
    } catch (e) {
      debugPrint('window save failed: $e');
    }
  }

  @override
  void onWindowResized() => _later();
  @override
  void onWindowMoved() => _later();
  @override
  void onWindowMaximize() => _later();
  @override
  void onWindowUnmaximize() => _later();
}
