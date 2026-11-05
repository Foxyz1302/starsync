import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../shell/mark_problem.dart';
import '../app/app_graph.dart';
import '../session/space_key.dart';
import 'text_focus.dart';

/// Tab and Shift+Tab never move focus, and Space never presses the
/// focused button (the app's [Shortcuts] override): Space is play / pause
/// and BRB, and a button keeps focus after a click. Text fields still type
/// spaces (their own shortcuts come first).
Map<ShortcutActivator, Intent> get appShortcuts => {
      ...WidgetsApp.defaultShortcuts,
      const SingleActivator(LogicalKeyboardKey.tab): const DoNothingIntent(),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true): const DoNothingIntent(),
      const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent(),
    };

/// The window's app-wide keys, ahead of whatever has focus: while in a
/// server, Space is the session's [SpaceKey] (a tap plays or pauses, a hold
/// is BRB; key-down, every frame while held, key-up; repeats ignored; a
/// press is dropped when the window loses the keys) and Tab opens or
/// closes the chat, on every tab and in every player mode. Not while a
/// text field has focus (the chat field handles Tab and Esc itself) nor
/// while a dialog or menu is in front of [child]. Any key is input for
/// AFK. Ctrl+Shift+B ([markProblemKey]) marks a problem anywhere, a text
/// field focused or not.
class AppKeys extends StatefulWidget {
  /// Who toggles the chat, latest first: the strip while it is shown, the
  /// full player in fullscreen (both hold the shell's toggle).
  static final _chatToggles = <VoidCallback>[];

  static void addChatToggle(VoidCallback f) => _chatToggles.add(f);
  static void removeChatToggle(VoidCallback f) => _chatToggles.remove(f);

  /// Space down; tests count presses instead of sending them.
  final VoidCallback? onSpace;
  final Widget child;
  const AppKeys({super.key, this.onSpace, required this.child});

  @override
  State<AppKeys> createState() => _AppKeysState();
}

class _AppKeysState extends State<AppKeys> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _hold = createTicker((elapsed) {
    _held = elapsed;
    _space?.tick(elapsed);
  });
  // How long the press under way has been held, on the frame clock.
  Duration _held = Duration.zero;
  // The press in progress goes to this session's key until its key-up.
  SpaceKey? _space;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    WidgetsBinding.instance.removeObserver(this);
    _hold.dispose();
    super.dispose();
  }

  /// The window lost the keys mid-press: its key-up may never come, so a
  /// held Space never turns into BRB in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _space?.cancel();
    _endPress();
  }

  void _endPress() {
    _space = null;
    if (_hold.isActive) _hold.stop();
  }

  bool _key(KeyEvent event) {
    if (!mounted) return false;
    final key = event.logicalKey;
    // The press under way ends with its own key-up, wherever focus went.
    if (key == LogicalKeyboardKey.space && _space != null) {
      if (event is KeyUpEvent) {
        _space!.keyUp(_held > Duration.zero ? _held : null);
        _endPress();
      }
      return true;
    }
    if (event is! KeyDownEvent) return false;
    if (widget.onSpace == null) AppScope.of(context).coordinator.markInput();
    if (markProblemKey.accepts(event, HardwareKeyboard.instance)) {
      if (ModalRoute.of(context)?.isCurrent == false) return false;
      showMarkProblem(context);
      return true;
    }
    if (key != LogicalKeyboardKey.space && key != LogicalKeyboardKey.tab) return false;
    if (!AppScope.of(context).navigation.online.peek()) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (textInputFocused()) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    if (key == LogicalKeyboardKey.space) {
      final test = widget.onSpace;
      if (test != null) {
        test();
        return true;
      }
      final space = AppScope.of(context).coordinator.space;
      space.keyDown();
      if (space.down) {
        _space = space;
        _held = Duration.zero;
        _hold.start();
      }
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
