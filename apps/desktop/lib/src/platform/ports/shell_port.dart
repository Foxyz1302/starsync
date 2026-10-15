import 'package:flutter/widgets.dart';

/// Where the app window stands, for auto sit-out
/// ([ShellPort.watchActivity]).
enum WindowActivity {
  /// The window has the keyboard focus.
  focused,

  /// Shown, but another window has the focus.
  unfocused,

  /// Minimised to the taskbar.
  minimised,

  /// Hidden (closing, or a platform that hides instead of minimising).
  hidden,
}

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

  /// Points the desktop at the window when it is not focused (taskbar
  /// flash, urgency hint); nothing when it is.
  Future<void> requestAttention();

  /// The clipboard's files, else its text (Ctrl+V outside a text field).
  Future<Paste> readPaste();

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
