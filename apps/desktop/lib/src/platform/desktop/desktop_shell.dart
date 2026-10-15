import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fox_utils/fox_utils.dart' show ClipboardX, DesktopDropX, DropTarget;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../state/settings.dart' show settingsBoxName;
import 'attention.dart';
import '../ports/shell_port.dart';
import 'window_memory.dart';

/// [ShellPort] on Linux and Windows: window_manager for the window,
/// [WindowMemory] for its size and place, the runner's channel for
/// attention, fox_utils for drops and the clipboard.
class DesktopShell implements ShellPort {
  WindowMemory? _memory;

  @override
  Future<void> start({required String title, required Future<void> Function() onCloseRequest}) async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    final memory = _memory = WindowMemory(Hive.isBoxOpen(settingsBoxName) ? Hive.box(settingsBoxName) : null);
    windowManager.addListener(_CloseGuard(onCloseRequest));
    final windowOptions = WindowOptions(
      size: memory.size,
      minimumSize: const Size(160, 90),
      center: !memory.hasPosition,
      backgroundColor: const Color(0xFF000000),
      titleBarStyle: TitleBarStyle.hidden,
      title: title,
    );
    unawaited(windowManager.waitUntilReadyToShow(windowOptions, () async {
      await memory.restore();
      await windowManager.show();
      await windowManager.focus();
    }));
  }

  @override
  Future<void> setFullScreen(bool on) => windowManager.setFullScreen(on);
  @override
  Future<void> minimize() => windowManager.minimize();
  @override
  Future<bool> isMaximized() => windowManager.isMaximized();
  @override
  Future<void> maximize() => windowManager.maximize();
  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  void Function() watchMaximized(void Function(bool maximized) onChange) {
    final l = _MaximizeWatch(onChange);
    windowManager.addListener(l);
    return () => windowManager.removeListener(l);
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> requestClose() => windowManager.close();

  @override
  Future<void> saveWindow() async => _memory?.save();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> quit() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (e) {
      debugPrint('window close failed: $e');
      await windowManager.destroy();
    }
  }

  @override
  Future<void> requestAttention() => requestWindowAttention();

  @override
  Future<Paste> readPaste() async {
    var files = const <String>[];
    String? text;
    try {
      files = await ClipboardX.readFiles();
    } catch (_) {}
    if (files.isEmpty) {
      try {
        text = await ClipboardX.readText();
      } catch (_) {}
    }
    return (files: files, text: text);
  }

  @override
  Widget dropTarget({
    Key? key,
    bool enable = true,
    VoidCallback? onEnter,
    VoidCallback? onExit,
    required void Function(List<String> paths, Offset at) onDrop,
    required Widget child,
  }) =>
      DropTarget(
        key: key,
        enable: enable,
        onDragEntered: onEnter == null ? null : (_) => onEnter(),
        onDragExited: onExit == null ? null : (_) => onExit(),
        onDragDone: (d) => onDrop(DesktopDropX.pathsOf(d.files), d.localPosition),
        child: child,
      );
}

/// Close button / Alt+F4 run the orderly close instead.
class _CloseGuard with WindowListener {
  final Future<void> Function() onClose;
  _CloseGuard(this.onClose);
  @override
  void onWindowClose() => unawaited(onClose());
}

class _MaximizeWatch with WindowListener {
  final void Function(bool) onChange;
  _MaximizeWatch(this.onChange);
  @override
  void onWindowMaximize() => onChange(true);
  @override
  void onWindowUnmaximize() => onChange(false);
}
