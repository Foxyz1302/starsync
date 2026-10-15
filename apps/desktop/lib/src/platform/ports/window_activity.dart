/// Where the app window stands ([ShellPort.watchActivity]): auto sit-out
/// and the Notifier (system notifications while it is not focused) read
/// it. Pure Dart.
enum WindowActivity {
  /// The window has the keyboard focus.
  focused,

  /// Shown, but another window has the focus.
  unfocused,

  /// Minimised to the taskbar.
  minimised,

  /// Hidden (closing, or a platform that hides instead of minimising).
  hidden;

  /// Not in front of the user: notices go out as system notifications.
  bool get background => this != focused;
}
