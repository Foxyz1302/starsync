import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';

import 'window_activity.dart';

export 'window_activity.dart';

/// What the clipboard holds for a paste: its files, else its text.
typedef Paste = ({List<String> files, String? text});

/// The app window and what the desktop hands it (drops, pastes). The
/// desktop implementation wraps window_manager and fox_utils
/// ([DesktopShell]); another platform brings its own.
abstract interface class ShellPort {
  /// Before the first frame: the window shown at its remembered size and
  /// place; a close request (close button, Alt+F4) runs [onCloseRequest]
  /// instead of closing.
  Future<void> start({required String title, required Future<void> Function() onCloseRequest});

  Future<void> setFullScreen(bool on);
  Future<void> minimize();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();

  /// Calls [onChange] whenever the window is maximized or restored;
  /// returns the call that stops it.
  void Function() watchMaximized(void Function(bool maximized) onChange);

  /// Calls [onChange] whenever the window gains or loses the focus, is
  /// minimised, restored or hidden; returns the call that stops it.
  void Function() watchActivity(void Function(WindowActivity activity) onChange);

  /// Moves the window with the pointer (a press on the title area).
  Future<void> startDragging();

  /// Asks to close the window: the same path as the close button.
  Future<void> requestClose();

  /// The way out: remembers the window, hides it ([hide]), and later
  /// closes it for good ([quit]).
  Future<void> saveWindow();
  Future<void> hide();
  Future<void> quit();

  /// Brings the window up and gives it the focus (restored when
  /// minimised, shown when hidden): a click on a system notification, a
  /// link handed over by a second start ([activation]: that start's
  /// desktop activation token, which lets the window take the focus).
  Future<void> focus({String activation = ''});

  /// Points the desktop at the window when it is not focused (taskbar
  /// flash, urgency hint); nothing when it is.
  Future<void> requestAttention();

  /// The clipboard's files, else its text (Ctrl+V outside a text field).
  Future<Paste> readPaste();

  /// The clipboard's text only (the join prompt looks for an invite in
  /// it); null when there is none or it can't be read.
  Future<String?> readClipboardText();

  /// The clipboard's picture (an image copied, or an image file copied in
  /// a file manager), encoded; null when it holds none.
  Future<Uint8List?> readImage();

  /// Puts the PNG [png] on the clipboard as an image (a screenshot);
  /// false when it could not.
  Future<bool> copyImage(Uint8List png);

  /// [child] taking dropped files ([onDrop]: their paths and where they
  /// landed); [enable] off lets drops through.
  Widget dropTarget({
    Key? key,
    bool enable = true,
    VoidCallback? onEnter,
    VoidCallback? onExit,
    required void Function(List<String> paths, Offset at) onDrop,
    required Widget child,
  });
}
