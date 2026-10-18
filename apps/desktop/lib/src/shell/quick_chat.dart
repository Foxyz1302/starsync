import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../widgets/app_menu.dart' show AppMenuStyle;
import 'avatar.dart';
import 'motion.dart';

// The quick chat box: Enter in the full player opens a small box at the
// bottom centre, in the control bar's place, without opening the chat
// panel. It types into the same draft as the chat panel's field.

/// The box's state, owned by the shell (it outlives the player's modes):
/// open or not, the draft ([draft], the chat panel's controller) and its
/// focus. What you send comes back like everyone's chat: your own chat
/// toast (or danmaku line), no separate echo.
class QuickChat {
  /// Closes by itself after this long without typing; the draft stays.
  static const idleClose = Duration(seconds: 8);

  /// The draft, shared with the chat panel's field.
  final TextEditingController draft;
  final bool _ownsDraft;
  final focus = FocusNode(debugLabel: 'quick chat');
  final open = ValueNotifier(false);

  /// Without typing this long, the box closes ([idleClose]).
  final Duration idle;
  Timer? _idleTimer;

  QuickChat({TextEditingController? draft, this.idle = idleClose})
      : draft = draft ?? TextEditingController(),
        _ownsDraft = draft == null {
    this.draft.addListener(_typed);
  }

  void dispose() {
    draft.removeListener(_typed);
    if (_ownsDraft) draft.dispose();
    _idleTimer?.cancel();
    focus.dispose();
    open.dispose();
  }

  /// Opens the box with the draft as it was, caret at its end, and gives
  /// it the keyboard at once (keys typed right after go to it).
  void show() {
    open.value = true;
    draft.selection = TextSelection.collapsed(offset: draft.text.length);
    focus.requestFocus();
    _armIdle();
  }

  /// Closes the box; the draft stays for the next Enter (or the panel).
  void close() {
    _idleTimer?.cancel();
    if (!open.value) return;
    open.value = false;
    focus.unfocus();
  }

  void _typed() {
    if (open.value) _armIdle();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, close);
  }

  /// Enter: the trimmed draft to send (cleared, the box closes), or null
  /// when blank (the box just closes).
  String? submit() {
    final text = draft.text.trim();
    close();
    if (text.isEmpty) return null;
    draft.clear();
    return text;
  }
}

/// The box: a glass pill at the bottom centre that starts compact
/// ([minWidth]) and widens with the text up to [maxWidth], then wraps to
/// up to four lines, growing upward. Enter sends ([onSend], empty Enter
/// closes), Esc closes. Your avatar leads it. While closed it stays
/// mounted, invisible and out of the way, so [QuickChat.show] focuses it
/// at once. The pointer over it stays hidden until the mouse moves.
class QuickChatBox extends StatefulWidget {
  static const minWidth = 300.0;
  static const height = 44.0;
  final QuickChat chat;
  final double maxWidth;
  final void Function(String text) onSend;

  /// Its height whenever it changes (the subtitle lift follows it).
  final ValueChanged<double>? onHeight;
  const QuickChatBox({super.key, required this.chat, required this.onSend, this.maxWidth = 640, this.onHeight});

  @override
  State<QuickChatBox> createState() => _QuickChatBoxState();
}

class _QuickChatBoxState extends State<QuickChatBox> {
  static const _text = TextStyle(color: Colors.white, fontSize: 15, height: 1.3);
  bool _pointerMoved = false;
  Offset? _pointerAt;

  QuickChat get c => widget.chat;

  @override
  void initState() {
    super.initState();
    c.draft.addListener(_changed);
    c.open.addListener(_openChanged);
  }

  @override
  void didUpdateWidget(QuickChatBox old) {
    super.didUpdateWidget(old);
    if (old.chat != widget.chat) {
      old.chat.draft.removeListener(_changed);
      old.chat.open.removeListener(_openChanged);
      c.draft.addListener(_changed);
      c.open.addListener(_openChanged);
    }
  }

  @override
  void dispose() {
    c.draft.removeListener(_changed);
    c.open.removeListener(_openChanged);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _openChanged() {
    if (c.open.value) _pointerMoved = false;
    setState(() {});
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      c.close();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      // An input method composing a word takes Enter itself.
      if (c.draft.value.composing.isValid) return KeyEventResult.ignored;
      if (e is KeyRepeatEvent) return KeyEventResult.handled;
      final text = c.submit();
      if (text != null) widget.onSend(text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Wide enough for the draft on one line, between [QuickChatBox.minWidth]
  /// and the room there is.
  double _width(double room) {
    final max = math.max(QuickChatBox.minWidth, math.min(widget.maxWidth, room));
    final tp = TextPainter(
      text: TextSpan(text: c.draft.text.isEmpty ? ' ' : c.draft.text, style: _text),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    // Avatar, gaps and padding around the text, plus room for the caret.
    final w = tp.width + 22 + 12 + 18 + 18 + 40;
    tp.dispose();
    return w.clamp(QuickChatBox.minWidth, max);
  }

  @override
  Widget build(BuildContext context) {
    final open = c.open.value;
    final me = selfAvatarInfo();
    return LayoutBuilder(builder: (context, box) {
      final width = _width(box.maxWidth);
      final field = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        child: TextField(
          key: const ValueKey('quick-chat-field'),
          controller: c.draft,
          focusNode: c.focus,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.send,
          maxLength: 500,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          // Enter is ours (above); a platform send action lands here.
          onSubmitted: (_) {
            final text = c.submit();
            if (text != null) widget.onSend(text);
          },
          mouseCursor: _pointerMoved ? SystemMouseCursors.text : SystemMouseCursors.none,
          style: _text,
          cursorColor: Colors.white,
          cursorWidth: 1.6,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            hintText: 'Say something',
            hintStyle: _text.copyWith(color: Colors.white.withValues(alpha: 0.42)),
          ),
        ),
      );
      return Align(
        alignment: Alignment.bottomCenter,
        child: IgnorePointer(
          ignoring: !open,
          child: AnimatedSlide(
            offset: open ? Offset.zero : const Offset(0, 0.35),
            duration: easeTime,
            curve: ease,
            child: AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: open ? easeTime : const Duration(milliseconds: 160),
              curve: ease,
              child: MouseRegion(
                onHover: (e) {
                  final at = _pointerAt;
                  _pointerAt = e.position;
                  if (!_pointerMoved && at != null && (e.position - at).distance > 0.5) {
                    setState(() => _pointerMoved = true);
                  }
                },
                child: _ReportHeight(
                  onHeight: widget.onHeight,
                  child: AnimatedContainer(
                    key: const ValueKey('quick-chat'),
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    width: width,
                    constraints: const BoxConstraints(minHeight: QuickChatBox.height),
                    padding: const EdgeInsets.fromLTRB(11, 6, 16, 6),
                    decoration: BoxDecoration(
                      color: AppMenuStyle.glass,
                      borderRadius: BorderRadius.circular(QuickChatBox.height / 2),
                      border: Border.all(color: Colors.white.withValues(alpha: open ? 0.22 : 0.1), width: 0.8),
                      boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 18, offset: Offset(0, 6))],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        StatusAvatar(info: me, size: 22, badges: false, ring: false),
                        const SizedBox(width: 12),
                        Expanded(child: field),
                        const SizedBox(width: 8),
                        Icon(Icons.keyboard_return_rounded, size: 16, color: Colors.white.withValues(alpha: 0.38)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Reports its child's height after layout when it changes.
class _ReportHeight extends SingleChildRenderObjectWidget {
  final ValueChanged<double>? onHeight;
  const _ReportHeight({required this.onHeight, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderReportHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderReportHeight r) => r.onHeight = onHeight;
}

class _RenderReportHeight extends RenderProxyBox {
  ValueChanged<double>? onHeight;
  double? _last;
  _RenderReportHeight(this.onHeight);

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _last) return;
    _last = h;
    final f = onHeight;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => f(h));
  }
}
