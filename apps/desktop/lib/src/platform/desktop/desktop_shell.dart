import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/services.dart' show MethodChannel;
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

  final _activity = <void Function(WindowActivity)>{};

  @override
  void Function() watchActivity(void Function(WindowActivity activity) onChange) {
    final l = _ActivityWatch(onChange);
    _activity.add(onChange);
    windowManager.addListener(l);
    return () {
      _activity.remove(onChange);
      windowManager.removeListener(l);
    };
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> requestClose() => windowManager.close();

  @override
  Future<void> saveWindow() async => _memory?.save();

  @override
  Future<void> hide() async {
    // window_manager has no hide event: tell the watchers here.
    for (final f in [..._activity]) {
      f(WindowActivity.hidden);
    }
    await windowManager.hide();
  }

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
  Future<void> focus({String activation = ''}) async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (!await windowManager.isVisible()) await windowManager.show();
      // Linux: present with the token when there is one (else a
      // compositor only marks the window as wanting attention).
      if (activation.isNotEmpty && await presentWindow(activation)) return;
      await windowManager.focus();
    } catch (e) {
      debugPrint('window focus failed: $e');
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
  Future<String?> readClipboardText() async {
    try {
      return await ClipboardX.readText();
    } catch (_) {
      return null;
    }
  }

  // Linux: the runner's own channel (linux/runner/clipboard_image.cc)
  // offers the PNG as `image/png` (fox_utils can only put a file there on
  // Linux, which chat apps and browsers do not paste as a picture).
  static const _clipboard = MethodChannel('starsync/clipboard');

  @override
  Future<bool> copyImage(Uint8List png) async {
    try {
      if (Platform.isLinux) return await _clipboard.invokeMethod<bool>('copyImage', png) ?? false;
      await ClipboardX.copyImage(png);
      return true;
    } catch (e) {
      debugPrint('copy image failed: $e');
      return false;
    }
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

/// Focus, blur, minimise and restore as [WindowActivity] (a restored
/// window is shown; its focus event follows when it gets the keyboard).
class _ActivityWatch with WindowListener {
  final void Function(WindowActivity) onChange;
  _ActivityWatch(this.onChange);
  @override
  void onWindowFocus() => onChange(WindowActivity.focused);
  @override
  void onWindowBlur() => onChange(WindowActivity.unfocused);
  @override
  void onWindowMinimize() => onChange(WindowActivity.minimised);
  @override
  void onWindowRestore() => onChange(WindowActivity.unfocused);
}
