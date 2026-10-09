import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/session_state.dart';
import 'text_focus.dart';

/// Tab and Shift+Tab never move focus, and Space never presses the
/// focused button (the app's [Shortcuts] override): Space is the ready key,
/// and a button keeps focus after a click. Text fields still type spaces
/// (their own shortcuts come first).
Map<ShortcutActivator, Intent> get appShortcuts => {
      ...WidgetsApp.defaultShortcuts,
      const SingleActivator(LogicalKeyboardKey.tab): const DoNothingIntent(),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true): const DoNothingIntent(),
      const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent(),
    };

/// The window's two app-wide keys, ahead of whatever has focus: while in a
/// server, Space is ready / not ready and Tab opens or closes the chat,
/// on every tab and in every player mode. Not while a text field has
/// focus (the chat field handles Tab and Esc itself) nor while a dialog or
/// menu is in front of [child].
class AppKeys extends StatefulWidget {
  /// Who toggles the chat, latest first: the strip while it is shown, the
  /// full player in fullscreen (both hold the shell's toggle).
  static final _chatToggles = <VoidCallback>[];

  static void addChatToggle(VoidCallback f) => _chatToggles.add(f);
  static void removeChatToggle(VoidCallback f) => _chatToggles.remove(f);

  /// Space; tests count presses instead of sending them.
  final VoidCallback? onToggleReady;
  final Widget child;
  const AppKeys({super.key, this.onToggleReady, required this.child});

  @override
  State<AppKeys> createState() => _AppKeysState();
}

class _AppKeysState extends State<AppKeys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.space && key != LogicalKeyboardKey.tab) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (textInputFocused()) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    if (key == LogicalKeyboardKey.space) {
      (widget.onToggleReady ?? SessionState.instance.coordinator.toggleReady)();
      return true;
    }
    final toggles = AppKeys._chatToggles;
    if (toggles.isEmpty) return false;
    toggles.last();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Registers [onToggle] with [AppKeys] while mounted.
class ChatKey extends StatefulWidget {
  final VoidCallback onToggle;
  final Widget child;
  const ChatKey({super.key, required this.onToggle, required this.child});

  @override
  State<ChatKey> createState() => _ChatKeyState();
}

class _ChatKeyState extends State<ChatKey> {
  void _toggle() => widget.onToggle();

  @override
  void initState() {
    super.initState();
    AppKeys.addChatToggle(_toggle);
  }

  @override
  void dispose() {
    AppKeys.removeChatToggle(_toggle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
