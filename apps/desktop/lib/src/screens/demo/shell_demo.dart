import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../jellyfin/accounts.dart';
import '../../sfx/sfx.dart';
import '../../sfx/sound_bank.dart';
import '../../sfx/synth.dart';
import '../../sfx/synth_sfx.dart';
import '../../widgets/window_buttons.dart';

part 'demo_files.dart';
part 'demo_player.dart';
part 'demo_schedule.dart';
part 'demo_settings.dart';
part 'demo_sounds.dart';

// DEBUG ONLY: a placeholder mock of the single-window layout (party strip,
// library with Jellyfin / Link / Files, click-to-select details, floating
// mini player that snaps to corners, chat panel and toasts). No real data,
// no networking. Opened from the bug button in Home's top bar (debug
// builds only). Edit freely with hot reload.

const _ease = Curves.fastEaseInToSlowEaseOut;
const _easeTime = Duration(milliseconds: 320);

/// Fade through (Material motion): the old view is gone after the first
/// 35%, then the new one fades and scales in; they never overlap.
Widget _fadeSwitch(Widget child, {Key? key}) => AnimatedSwitcher(
  key: key,
  duration: const Duration(milliseconds: 360),
  layoutBuilder: (current, previous) => Stack(
    fit: StackFit.expand,
    children: [...previous, if (current != null) current],
  ),
  transitionBuilder: (c, anim) {
    if (c.key == child.key) {
      // Incoming (anim 0 -> 1): wait, then fade and scale up.
      final a = CurvedAnimation(
        parent: anim,
        curve: const Interval(0.35, 1, curve: _ease),
      );
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.985, end: 1.0).animate(a),
          child: c,
        ),
      );
    }
    // Outgoing (anim 1 -> 0): fully faded by the time it reaches 0.65.
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: anim,
        curve: const Interval(0.65, 1, curve: Curves.easeIn),
      ),
      child: c,
    );
  },
  child: child,
);

/// Popover: fades and scales in from its anchor instead of popping.
Future<void> _popover(
  BuildContext context, {
  required Alignment at,
  required Widget child,
  bool dim = false,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'close',
  barrierColor: dim ? Colors.black26 : Colors.transparent,
  transitionDuration: _easeTime,
  // Short windows: the card scrolls instead of overflowing.
  pageBuilder: (context, _, __) => Align(
    alignment: at,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height - 32,
      ),
      child: SingleChildScrollView(child: child),
    ),
  ),
  transitionBuilder: (context, anim, _, child) {
    final a = CurvedAnimation(
      parent: anim,
      curve: _ease,
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.0).animate(a),
        alignment: at,
        child: child,
      ),
    );
  },
);

class ShellDemo extends StatefulWidget {
  const ShellDemo({super.key});

  @override
  State<ShellDemo> createState() => _ShellDemoState();
}

enum _Player { none, mini, full }

enum _Source { jellyfin, link, file }

class _Member {
  final String name;
  final Color color;
  final bool ready, buffering, relaying, stale, host;

  /// Cropped 256 px PNG; null shows the initial on [color].
  final Uint8List? avatar;
  const _Member(
    this.name,
    this.color, {
    this.avatar,
    this.ready = false,
    this.buffering = false,
    this.relaying = false,
    this.stale = false,
    this.host = false,
  });

  _Member copyWith({
    String? name,
    Color? color,
    Uint8List? avatar,
    bool clearAvatar = false,
  }) => _Member(
    name ?? this.name,
    color ?? this.color,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
    ready: ready,
    buffering: buffering,
    relaying: relaying,
    stale: stale,
    host: host,
  );
}

/// This app's own profile: editable mid-session, everything rebuilds from it.
final _me = ValueNotifier(
  const _Member('Foxyz', Colors.deepPurple, ready: true, host: true),
);

List<_Member> get _members => [_me.value, ..._others];

const _others = [
  _Member('Bob', Colors.teal, ready: true, relaying: true),
  _Member('Alex', Colors.orange, buffering: true),
  _Member('Mika', Colors.pink),
  _Member('Sam', Colors.blue, ready: true),
  _Member('Kei', Colors.green, stale: true),
];

_Member _m(String name) => _members.firstWhere((m) => m.name == name);

class _Toast {
  final int id;
  final _Member who;
  final IconData? icon;
  final String text;
  final bool chat;
  bool leaving = false;
  _Toast(this.id, this.who, this.text, {this.icon, this.chat = false});
}

class _ShellDemoState extends State<ShellDemo> {
  void _meChanged() => setState(() {});
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _me.addListener(_meChanged);
    _nowPlaying.addListener(_meChanged);
  }

  @override
  void dispose() {
    _me.removeListener(_meChanged);
    _nowPlaying.removeListener(_meChanged);
    if (_fullscreen) _setWindowFullscreen(false);
    unawaited(_disposeDemoPlayer());
    super.dispose();
  }

  Future<void> _setWindowFullscreen(bool on) async {
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {
      // No window manager (tests).
    }
  }

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      if (_fullscreen) _player = _Player.full;
    });
    _setWindowFullscreen(_fullscreen);
  }

  void _say(String text) =>
      _toast(_Toast(++_toastId, _me.value, text, icon: Icons.info_outline));

  bool _online = true;
  _Player _player = _Player.mini;
  int? _selected;
  String _tab = 'Library';
  _Source _source = _Source.jellyfin;
  bool _chatOpen = false;
  int _unread = 2;
  final _toasts = <_Toast>[];
  var _toastId = 0;

  void _toast(_Toast t) {
    if (!mounted) return;
    setState(() => _toasts.add(t));
    Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => t.leaving = true);
    });
    Timer(const Duration(seconds: 5) + _easeTime, () {
      if (mounted) setState(() => _toasts.removeWhere((x) => x.id == t.id));
    });
  }

  void _demoToasts() {
    _toast(
      _Toast(
        ++_toastId,
        _m('Bob'),
        'anyone else think the OP slaps?',
        chat: true,
      ),
    );
    Timer(
      const Duration(milliseconds: 500),
      () => _toast(
        _Toast(++_toastId, _m('Alex'), 'is ready', icon: Icons.check_circle),
      ),
    );
    Timer(
      const Duration(milliseconds: 1000),
      () => _toast(
        _Toast(
          ++_toastId,
          _m('Sam'),
          'skipped to 1:30',
          icon: Icons.fast_forward,
        ),
      ),
    );
    Timer(
      const Duration(milliseconds: 1500),
      () => _toast(
        _Toast(
          ++_toastId,
          _m('Bob'),
          'put up S1E4 · passing it on',
          icon: Icons.swap_horiz,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _RealFullPlayer(
                fullscreen: true,
                onCollapse: _toggleFullscreen,
                onToggleFullscreen: _toggleFullscreen,
                partyOverlay: _online ? _AvatarStack(onTap: () {}) : null,
              ),
            ),
            Positioned(
              left: 16,
              bottom: 90,
              child: _ToastColumn(toasts: _toasts),
            ),
          ],
        ),
      );
    }
    final body = _player == _Player.full
        ? _RealFullPlayer(
            fullscreen: false,
            onCollapse: () => setState(() => _player = _Player.mini),
            onToggleFullscreen: _toggleFullscreen,
          )
        : switch (_tab) {
            'Library' => _Library(
              source: _source,
              onSource: (s) => setState(() => _source = s),
              selected: _selected,
              online: _online,
              onSelect: (i) =>
                  setState(() => _selected = _selected == i ? null : i),
              onPutUp: () => setState(() => _player = _Player.full),
            ),
            'Schedule' => _ScheduleTab(
              online: _online,
              onPlay: () => setState(() => _player = _Player.full),
              onToast: _say,
            ),
            _ => _SettingsTab(
              onOpenPlayerSettings: () => _popover(
                context,
                at: Alignment.center,
                dim: true,
                child: const _PlayerSettingsCard(),
              ),
            ),
          };
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(
        children: [
          _PartyStrip(
            onProfileChanged: (before, after) => _toast(
              _Toast(
                ++_toastId,
                _me.value,
                'was $before',
                icon: Icons.badge_outlined,
              ),
            ),
            online: _online,
            tab: _tab,
            unread: _unread,
            chatOpen: _chatOpen,
            onTab: (t) => setState(() {
              _tab = t;
              if (_player == _Player.full) _player = _Player.mini;
            }),
            onChat: () => setState(() {
              _chatOpen = !_chatOpen;
              _unread = 0;
            }),
            onDemoToasts: _demoToasts,
            onToggleOnline: () => setState(() {
              _online = !_online;
              if (!_online) _player = _Player.none;
            }),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _fadeSwitch(
                          KeyedSubtree(
                            key: ValueKey(
                              _player == _Player.full ? 'player' : _tab,
                            ),
                            child: body,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: _player != _Player.mini,
                          child: AnimatedOpacity(
                            duration: _easeTime,
                            curve: _ease,
                            opacity: _player == _Player.mini ? 1 : 0,
                            child: AnimatedScale(
                              duration: _easeTime,
                              curve: _ease,
                              scale: _player == _Player.mini ? 1 : 0.97,
                              child: Stack(
                                children: [
                                  _FloatingMini(
                                    active: _player == _Player.mini,
                                    onExpand: () =>
                                        setState(() => _player = _Player.full),
                                    onClose: () =>
                                        setState(() => _player = _Player.none),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        bottom: 16,
                        child: _ToastColumn(toasts: _toasts),
                      ),
                    ],
                  ),
                ),
                AnimatedSize(
                  duration: _easeTime,
                  curve: _ease,
                  alignment: Alignment.centerLeft,
                  child: _chatOpen && _online
                      ? _ChatPanel(
                          onClose: () => setState(() => _chatOpen = false),
                        )
                      : const SizedBox(height: double.infinity),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ party strip

class _PartyStrip extends StatelessWidget {
  final bool online, chatOpen;
  final String tab;
  final int unread;
  final ValueChanged<String> onTab;
  final VoidCallback onToggleOnline, onChat, onDemoToasts;
  final void Function(String before, String after) onProfileChanged;
  const _PartyStrip({
    required this.onProfileChanged,
    required this.online,
    required this.tab,
    required this.unread,
    required this.chatOpen,
    required this.onTab,
    required this.onChat,
    required this.onDemoToasts,
    required this.onToggleOnline,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Narrow windows: fewer avatars, no server text, so the tabs keep room.
    final compact = MediaQuery.sizeOf(context).width < 1100;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Back to the current app (demo)',
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: 'Your profile',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _showProfile(
              context,
              online: online,
              onChanged: onProfileChanged,
            ),
            child: _Avatar(member: _me.value, size: 32),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _HScroll(
            builder: (c) => SingleChildScrollView(
              controller: c,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in ['Library', 'Schedule', 'Settings'])
                    _StripTab(
                      label: t,
                      selected: t == tab,
                      onTap: () => onTab(t),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (!compact)
          IconButton(
            tooltip: 'Demo: fire some toasts',
            onPressed: onDemoToasts,
            icon: const Icon(
              Icons.notifications_active_outlined,
              size: 20,
              color: Colors.amber,
            ),
          ),
        if (online) ...[
          _AvatarStack(
            onTap: () => _showMembers(context),
            shown: compact ? 3 : 5,
          ),
          const SizedBox(width: 10),
          if (!compact)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'VPS',
                  style: TextStyle(fontWeight: FontWeight.w600, height: 1.1),
                ),
                Text(
                  'ready 3/6',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          const SizedBox(width: 6),
          Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: IconButton(
              tooltip: 'Chat & activity',
              isSelected: chatOpen,
              onPressed: onChat,
              icon: const Icon(Icons.chat_bubble_outline, size: 20),
              selectedIcon: Icon(
                Icons.chat_bubble,
                size: 20,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton(onPressed: onToggleOnline, child: const Text('Leave')),
        ] else ...[
          Text('Offline', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: () =>
                _showConnect(context, host: false, onDone: onToggleOnline),
            child: const Text('Join'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () =>
                _showConnect(context, host: true, onDone: onToggleOnline),
            child: const Text('Host'),
          ),
        ],
        const SizedBox(width: 8),
        SizedBox(
          height: 20,
          child: VerticalDivider(width: 12, color: scheme.outlineVariant),
        ),
        const WindowButtons(),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: SizedBox(
        height: 60,
        child: Stack(
          children: [
            const Positioned.fill(
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
            Positioned.fill(child: row),
          ],
        ),
      ),
    );
  }

  void _showMembers(BuildContext context) {
    _popover(
      context,
      at: const Alignment(0.7, -0.84),
      child: Builder(
        builder: (context) => Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 340,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Text(
                    'In the party · vps.example:8080',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                for (final m in _members)
                  ListTile(
                    dense: true,
                    leading: _Avatar(member: m, size: 36),
                    title: Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(m.name),
                        if (m.host) const _Pill('host', Colors.amber),
                        if (m.relaying)
                          const _Pill(
                            'passing the video on',
                            Colors.lightBlueAccent,
                          ),
                      ],
                    ),
                    subtitle: Text(
                      m.stale
                          ? 'reconnecting…'
                          : m.buffering
                          ? 'buffering 2.1 s'
                          : m.ready
                          ? 'ready'
                          : 'not ready',
                    ),
                    trailing: const Icon(Icons.more_vert, size: 18),
                  ),
                const Divider(),
                TextButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy invite address'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showConnect(
    BuildContext context, {
    required bool host,
    required VoidCallback onDone,
  }) {
    _popover(
      context,
      dim: true,
      at: const Alignment(0.8, -0.75),
      child: Builder(
        builder: (context) => Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    host ? 'Host a server' : 'Join a server',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  if (!host) ...[
                    const Text('Recent', style: TextStyle(color: Colors.grey)),
                    for (final s in [
                      'VPS · vps.example:8080',
                      'Bob · 192.168.1.20:8080',
                    ])
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.history, size: 18),
                        title: Text(s),
                        trailing: const Icon(Icons.login, size: 18),
                        onTap: () {
                          Navigator.of(context).pop();
                          onDone();
                        },
                      ),
                    const Divider(),
                    const TextField(
                      decoration: InputDecoration(
                        labelText: 'Address',
                        isDense: true,
                      ),
                    ),
                  ] else
                    const TextField(
                      decoration: InputDecoration(
                        labelText: 'Port',
                        hintText: '8080',
                        isDense: true,
                      ),
                    ),
                  const SizedBox(height: 8),
                  const TextField(
                    decoration: InputDecoration(
                      labelText: 'Password (optional)',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onDone();
                    },
                    child: Text(host ? 'Host' : 'Join'),
                  ),
                  if (host)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'You pick what to watch afterwards, in the library.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StripTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _StripTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width < 1100 ? 8 : 12,
        ),
        child: SizedBox(
          height: 60,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: _easeTime,
                curve: _ease,
                height: 3,
                width: selected ? 22 : 0,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

class _AvatarStack extends StatefulWidget {
  final VoidCallback onTap;

  /// Avatars before "+N".
  final int shown;
  const _AvatarStack({required this.onTap, this.shown = 5});

  @override
  State<_AvatarStack> createState() => _AvatarStackState();
}

class _AvatarStackState extends State<_AvatarStack> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const size = 42.0;
    final shown = widget.shown;
    // Host first, then ready: the stack itself reads as progress.
    int rank(_Member m) => m.host ? 0 : (m.ready ? 1 : 2);
    final sorted = [..._members]..sort((a, b) => rank(a) - rank(b));
    final visible = sorted.take(shown).toList();
    final extra = _members.length - visible.length;
    final step = _hover ? size + 6 : size * 0.62;
    final width = step * (visible.length - 1) + size + (extra > 0 ? step : 0);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: _easeTime,
          curve: _ease,
          width: width,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = visible.length - 1; i >= 0; i--)
                AnimatedPositioned(
                  duration: _easeTime,
                  curve: _ease,
                  left: i * step,
                  top: 0,
                  child: Tooltip(
                    message: visible[i].name,
                    child: _Avatar(member: visible[i], size: size),
                  ),
                ),
              if (extra > 0)
                AnimatedPositioned(
                  duration: _easeTime,
                  curve: _ease,
                  left: visible.length * step,
                  top: 0,
                  child: CircleAvatar(
                    radius: size / 2,
                    child: Text(
                      '+$extra',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circle avatar with a status ring outside it and a gap in the background
/// colour, so overlapping neighbours never hide the status. Crown = host,
/// tower = passing the video on.
class _Avatar extends StatelessWidget {
  final _Member member;
  final double size;

  /// Host crown and relay tower; off where the context already says it.
  final bool badges;
  const _Avatar({required this.member, required this.size, this.badges = true});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerLowest;
    final ring = member.stale
        ? Colors.grey.shade700
        : member.ready
        ? Colors.greenAccent.shade400
        : member.buffering
        ? Colors.amber
        : Colors.grey;
    final badge = size * 0.42;
    // Ring and gap scale with the avatar (2 px at strip size).
    final stroke = (size * 0.055).clamp(2.0, 4.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Fills the box: a non-positioned child of a Stack only gets loose
          // constraints, and CircleAvatar then falls back to its 40 px default.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
              padding: EdgeInsets.all(stroke),
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                padding: EdgeInsets.all(stroke),
                child: Opacity(
                  opacity: member.stale ? 0.4 : 1,
                  child: CircleAvatar(
                    radius: size / 2,
                    backgroundColor: member.color,
                    backgroundImage: member.avatar == null
                        ? null
                        : MemoryImage(member.avatar!),
                    child: member.avatar != null
                        ? null
                        : Text(
                            member.name[0],
                            style: TextStyle(
                              fontSize: size * 0.38,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (member.buffering)
            Positioned.fill(
              child: CircularProgressIndicator(
                strokeWidth: stroke,
                color: ring,
              ),
            ),
          if (badges && member.host)
            Positioned(
              left: -4,
              top: -6,
              child: Transform.rotate(
                angle: -0.4,
                child: Icon(
                  Icons.workspace_premium,
                  size: badge,
                  color: Colors.amber,
                  shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
                ),
              ),
            ),
          if (badges && member.relaying)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: Icon(
                  Icons.cell_tower,
                  size: badge * 0.8,
                  color: Colors.lightBlueAccent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- chat & toasts

class _ToastColumn extends StatelessWidget {
  final List<_Toast> toasts;
  const _ToastColumn({required this.toasts});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in toasts)
          TweenAnimationBuilder<double>(
            key: ValueKey(t.id),
            tween: Tween(begin: 0, end: 1),
            duration: _easeTime,
            curve: _ease,
            builder: (context, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(-24 * (1 - v), 0),
                child: child,
              ),
            ),
            // Leaving: slide back out, fade, and collapse the gap it leaves.
            child: AnimatedAlign(
              duration: _easeTime,
              curve: _ease,
              alignment: Alignment.topLeft,
              heightFactor: t.leaving ? 0 : 1,
              child: AnimatedSlide(
                duration: _easeTime,
                curve: _ease,
                offset: t.leaving ? const Offset(-0.25, 0) : Offset.zero,
                child: AnimatedOpacity(
                  duration: _easeTime,
                  curve: _ease,
                  opacity: t.leaving ? 0 : 1,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ToastCard(toast: t),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ToastCard extends StatelessWidget {
  final _Toast toast;
  const _ToastCard({required this.toast});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(member: toast.who, size: 38),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          toast.who.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        if (toast.icon != null) ...[
                          const SizedBox(width: 6),
                          Icon(toast.icon, size: 16, color: scheme.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      toast.text,
                      style: TextStyle(
                        fontSize: toast.chat ? 15 : 14,
                        color: toast.chat
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatPanel extends StatelessWidget {
  final VoidCallback onClose;
  const _ChatPanel({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final log = <(String, String, IconData?)>[
      ('Bob', 'joined', Icons.login),
      ('Bob', 'put up S1E3 · passing it on', Icons.swap_horiz),
      ('Foxyz', 'everyone here? starting in a sec', null),
      ('Alex', 'is ready', Icons.check_circle),
      ('Mika', 'brb 2 min', null),
      ('Sam', 'skipped to 1:30', Icons.fast_forward),
      ('Bob', 'anyone else think the OP slaps?', null),
    ];
    return Container(
      width: 340,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                const Text(
                  'Chat & activity',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final (who, text, icon) in log)
                  icon != null
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              Icon(
                                icon,
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '$who $text',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Avatar(member: _m(who), size: 34),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      who,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(text),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Message (Enter)',
                isDense: true,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: const Icon(Icons.send, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- library

class _Library extends StatelessWidget {
  final _Source source;
  final ValueChanged<_Source> onSource;
  final int? selected;
  final bool online;
  final ValueChanged<int> onSelect;
  final VoidCallback onPutUp;
  const _Library({
    required this.source,
    required this.onSource,
    required this.selected,
    required this.online,
    required this.onSelect,
    required this.onPutUp,
  });

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<_Source>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _Source.jellyfin,
                icon: Icon(Icons.video_library_outlined),
                label: Text('Jellyfin'),
              ),
              ButtonSegment(
                value: _Source.link,
                icon: Icon(Icons.link),
                label: Text('Link'),
              ),
              ButtonSegment(
                value: _Source.file,
                icon: Icon(Icons.folder_outlined),
                label: Text('Files'),
              ),
            ],
            selected: {source},
            onSelectionChanged: (s) => onSource(s.first),
          ),
          if (source == _Source.jellyfin)
            Wrap(
              spacing: 8,
              children: [
                for (final l in ['Anime', 'Movies', 'Shows'])
                  ActionChip(
                    label: Text(l),
                    avatar: const Icon(Icons.video_library_outlined, size: 16),
                    onPressed: () {},
                  ),
              ],
            ),
        ],
      ),
    );
    final content = switch (source) {
      _Source.jellyfin => _JellyfinHome(
        selected: selected,
        onSelect: onSelect,
        onPutUp: onPutUp,
      ),
      _Source.link => _LinkTab(online: online, onPutUp: onPutUp),
      _Source.file => _RealFilesTab(online: online, onPlay: onPutUp),
    };
    final open = source == _Source.jellyfin && selected != null;
    // Content cross-fades when another series is picked; the panel itself
    // slides in and out.
    final details = _fadeSwitch(
      selected == null
          ? const SizedBox.shrink()
          : KeyedSubtree(
              key: ValueKey(selected),
              child: _Details(
                id: selected!,
                online: online,
                onPutUp: onPutUp,
                onClose: () => onSelect(selected!),
              ),
            ),
    );
    final main = Column(
      children: [
        header,
        Expanded(
          child: _fadeSwitch(
            KeyedSubtree(key: ValueKey(source), child: content),
          ),
        ),
      ],
    );
    Widget slide(Widget child) => AnimatedSlide(
      duration: _easeTime,
      curve: _ease,
      offset: open ? Offset.zero : const Offset(1, 0),
      child: AnimatedOpacity(
        duration: _easeTime,
        curve: _ease,
        opacity: open ? 1 : 0,
        child: child,
      ),
    );
    // Wide: details dock beside the library. Narrow: they float over it.
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 1000) {
          return Row(
            children: [
              Expanded(child: main),
              ClipRect(
                child: AnimatedContainer(
                  duration: _easeTime,
                  curve: _ease,
                  width: open ? 400 : 0,
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 400,
                    maxWidth: 400,
                    child: slide(SizedBox(width: 400, child: details)),
                  ),
                ),
              ),
            ],
          );
        }
        return Stack(
          children: [
            Positioned.fill(child: main),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 400,
              child: IgnorePointer(
                ignoring: !open,
                child: slide(Material(elevation: 16, child: details)),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _JellyfinHome extends StatelessWidget {
  final int? selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onPutUp;
  const _JellyfinHome({
    required this.selected,
    required this.onSelect,
    required this.onPutUp,
  });

  @override
  Widget build(BuildContext context) {
    final rows = ['Continue', 'Latest in Anime', 'Latest in Movies'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  rows[r],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(onPressed: () {}, child: const Text('Show all')),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 264,
            child: _HScroll(
              builder: (c) => ListView.separated(
                controller: c,
                scrollDirection: Axis.horizontal,
                itemCount: 12,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final id = r * 100 + i;
                  return _Card(
                    title: 'Series ${id + 1}',
                    sub: r == 0 ? 'S1E${i + 2} · 12 min left' : 'S1E${i + 1}',
                    selected: selected == id,
                    onTap: () => onSelect(id),
                    onDouble: onPutUp,
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

class _LinkTab extends StatefulWidget {
  final bool online;
  final VoidCallback onPutUp;
  const _LinkTab({required this.online, required this.onPutUp});

  @override
  State<_LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends State<_LinkTab> {
  int _mode = 0;
  static const _modes = [
    (
      Icons.groups_outlined,
      'Everyone fetches it',
      'Each app plays the link itself.',
    ),
    (
      Icons.dns_outlined,
      'Server fetches it',
      'Downloaded once by the server. For links slow or blocked for some.',
    ),
    (
      Icons.cell_tower,
      'Through me',
      'Your computer passes it on. For links only you can open.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(Icons.link, size: 32, color: scheme.primary),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Watch from a link',
                textAlign: TextAlign.center,
                style: t.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'A video file, YouTube, a Jellyfin link… Ctrl+V anywhere pastes it here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'https://…',
                        prefixIcon: const Icon(Icons.link),
                        suffixIcon: IconButton(
                          onPressed: () {},
                          tooltip: 'Paste',
                          icon: const Icon(Icons.content_paste),
                        ),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: widget.onPutUp,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(widget.online ? 'Put it up' : 'Play'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // What the pasted link resolves to.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 176,
                        height: 99,
                        color: scheme.surfaceContainerHighest,
                        child: const Center(
                          child: Icon(Icons.image_outlined, color: Colors.grey),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Resolved title of the link',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'youtube.com · 23:41',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.online) ...[
                const SizedBox(height: 28),
                Text('How the others get it', style: t.titleSmall),
                const SizedBox(height: 10),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _modes.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _ModeCard(
                            mode: _modes[i],
                            selected: _mode == i,
                            onTap: () => setState(() => _mode = i),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
              Text('Recent', style: t.titleSmall),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, box) {
                  const gap = 12.0;
                  final cols = box.maxWidth > 600 ? 3 : 2;
                  final w = (box.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < 6; i++)
                        SizedBox(
                          width: w,
                          child: InkWell(
                            onTap: widget.onPutUp,
                            borderRadius: BorderRadius.circular(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: scheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.image_outlined,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Recent link title ${i + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  i.isEven
                                      ? 'youtube.com · 2 days ago'
                                      : 'cdn.example · last week',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final (IconData, String, String) mode;
  final bool selected;
  final VoidCallback onTap;
  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, sub) = mode;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: _easeTime,
        curve: _ease,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.primary : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String title, sub;
  final bool selected;
  final VoidCallback onTap, onDouble;
  const _Card({
    required this.title,
    required this.sub,
    required this.selected,
    required this.onTap,
    required this.onDouble,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDouble,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: _ease,
                  height: 200,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? scheme.primary : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.image_outlined,
                      size: 36,
                      color: Colors.grey,
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: CircleAvatar(
                      radius: 11,
                      backgroundColor: scheme.primary,
                      child: Icon(
                        Icons.check,
                        size: 14,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.primary : null,
              ),
            ),
            Text(sub, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  final int id;
  final bool online;
  final VoidCallback onPutUp, onClose;
  const _Details({
    required this.id,
    required this.online,
    required this.onPutUp,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 400,
      color: scheme.surfaceContainerLow,
      child: ListView(
        children: [
          Stack(
            children: [
              Container(
                height: 180,
                color: scheme.surfaceContainerHighest,
                child: const Center(
                  child: Text(
                    'banner / backdrop',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
              Positioned(
                right: 4,
                top: 4,
                child: IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Series ${id + 1}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text(
                  '2025 · 12 episodes · TV-14',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onPutUp,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        online ? 'Put it up · S1E3' : 'Play alone · S1E3',
                      ),
                    ),
                    IconButton(
                      onPressed: () {},
                      tooltip: 'Mark watched',
                      icon: const Icon(Icons.check_circle_outline),
                    ),
                    IconButton(
                      onPressed: () {},
                      tooltip: 'Remove from Continue',
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Overview placeholder text that describes the series in two or three lines, '
                  'so the panel has something to show at its real size.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Episodes',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (var e = 1; e <= 6; e++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 64,
                      height: 36,
                      color: scheme.surfaceContainerHighest,
                    ),
                    title: Text('E$e · Episode title'),
                    subtitle: Text(e < 3 ? 'watched' : '24 min'),
                    trailing: e == 3
                        ? Icon(Icons.play_circle, color: scheme.primary)
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- player

/// Picture-in-picture box: drag it anywhere, it snaps to the nearest
/// corner on release (eased). Double-click or ⤢ expands.
class _FloatingMini extends StatefulWidget {
  final VoidCallback onExpand, onClose;

  /// Shows the video (false while the full player has it).
  final bool active;
  const _FloatingMini({
    required this.onExpand,
    required this.onClose,
    this.active = true,
  });

  @override
  State<_FloatingMini> createState() => _FloatingMiniState();
}

class _FloatingMiniState extends State<_FloatingMini> {
  static const _w = 384.0, _h = 216.0, _margin = 16.0;
  Alignment _corner = Alignment.bottomRight;
  Offset? _drag; // top-left while dragging
  bool _hover = false;

  Offset _cornerPos(Size area, Alignment a) => Offset(
    a.x < 0 ? _margin : area.width - _w - _margin,
    a.y < 0 ? _margin : area.height - _h - _margin,
  );

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) {
          final area = box.biggest;
          final pos = _drag ?? _cornerPos(area, _corner);
          return Stack(
            children: [
              AnimatedPositioned(
                duration: _drag == null ? _easeTime : Duration.zero,
                curve: _ease,
                left: pos.dx,
                top: pos.dy,
                width: _w,
                height: _h,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hover = true),
                  onExit: (_) => setState(() => _hover = false),
                  child: GestureDetector(
                    onPanStart: (_) => setState(() => _drag = pos),
                    onPanUpdate: (d) =>
                        setState(() => _drag = _drag! + d.delta),
                    onPanEnd: (_) => setState(() {
                      final c = _drag! + const Offset(_w / 2, _h / 2);
                      _corner = Alignment(
                        c.dx < area.width / 2 ? -1 : 1,
                        c.dy < area.height / 2 ? -1 : 1,
                      );
                      _drag = null;
                    }),
                    onDoubleTap: widget.onExpand,
                    child: Material(
                      elevation: 16,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      color: Colors.black,
                      child: Stack(
                        children: [
                          // Only one Video per controller: not while the full
                          // player shows it.
                          Positioned.fill(
                            child: widget.active
                                ? const _VideoSurface(placeholderSize: 18)
                                : const ColoredBox(color: Colors.black),
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 160),
                            opacity: _hover ? 1 : 0,
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black54,
                                    Colors.transparent,
                                    Colors.black87,
                                  ],
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          [
                                            _nowPlaying.value?.title,
                                            _nowPlaying.value?.subtitle,
                                          ].whereType<String>().join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: widget.onExpand,
                                        tooltip: 'Expand',
                                        icon: const Icon(
                                          Icons.open_in_full,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: widget.onClose,
                                        tooltip:
                                            'Stop watching (stay in the party)',
                                        icon: const Icon(
                                          Icons.close,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  const _Transport(
                                    compact: true,
                                    trailing: [
                                      Text(
                                        'waiting for Alex',
                                        style: TextStyle(
                                          color: Colors.amber,
                                          fontSize: 12,
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Progress line while the controls are hidden.
                          if (!_hover && _demoPlayer != null)
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _ThinProgress(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Your profile: name and avatar apply live (the party sees the change at
/// once, an activity line says who you were); links to the app-wide pages.
Future<void> _showProfile(
  BuildContext context, {
  required bool online,
  required void Function(String before, String after) onChanged,
}) async {
  final before = _me.value.name;
  await _popover(
    context,
    at: const Alignment(-0.97, -0.84),
    child: _ProfileCard(online: online),
  );
  if (_me.value.name != before) onChanged(before, _me.value.name);
}

class _ProfileCard extends StatefulWidget {
  final bool online;
  const _ProfileCard({required this.online});

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  late final _name = TextEditingController(text: _me.value.name);
  bool _hoverPic = false;
  static const _colors = [
    Colors.deepPurple,
    Colors.indigo,
    Colors.teal,
    Colors.pink,
    Colors.orange,
    Colors.blueGrey,
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 12,
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        child: ValueListenableBuilder(
          valueListenable: _me,
          builder: (context, me, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header tinted with your colour.
              AnimatedContainer(
                duration: _easeTime,
                curve: _ease,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      me.color.withValues(alpha: 0.55),
                      me.color.withValues(alpha: 0.08),
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _hoverPic = true),
                      onExit: (_) => setState(() => _hoverPic = false),
                      child: GestureDetector(
                        onTap: () => _popover(
                          context,
                          at: Alignment.center,
                          dim: true,
                          child: const _CropPicker(),
                        ),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: Stack(
                            children: [
                              _Avatar(member: me, size: 88, badges: false),
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  duration: _easeTime,
                                  curve: _ease,
                                  opacity: _hoverPic ? 1 : 0,
                                  child: Container(
                                    margin: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black54,
                                    ),
                                    child: const Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.photo_camera_outlined,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                        Text(
                                          'Change',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _name,
                            maxLength: 32,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                            decoration: const InputDecoration(
                              isDense: true,
                              counterText: '',
                              border: InputBorder.none,
                              hintText: 'Your name',
                              suffixIcon: Icon(Icons.edit_outlined, size: 16),
                              suffixIconConstraints: BoxConstraints(
                                minWidth: 20,
                              ),
                            ),
                            onChanged: (v) {
                              if (v.trim().isNotEmpty) {
                                _me.value = me.copyWith(name: v.trim());
                              }
                            },
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (me.host) const _Pill('host', Colors.amber),
                              _Pill(
                                widget.online ? 'in VPS' : 'offline',
                                widget.online
                                    ? Colors.greenAccent
                                    : Colors.grey,
                              ),
                              if (widget.online)
                                _Pill(
                                  me.ready ? 'ready' : 'not ready',
                                  Colors.lightBlueAccent,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Row(
                  children: [
                    Text(
                      'Colour',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    for (final c in _colors)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _me.value = me.copyWith(color: c),
                          child: AnimatedContainer(
                            duration: _easeTime,
                            curve: _ease,
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: me.color == c
                                    ? scheme.onSurface
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (me.avatar != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      ValueListenableBuilder(
                        valueListenable: _avatarInfo,
                        builder: (context, info, _) => Text(
                          info ?? 'picture',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () =>
                            _me.value = me.copyWith(clearAvatar: true),
                        child: const Text('Remove picture'),
                      ),
                    ],
                  ),
                ),
              if (widget.online)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                  child: Text(
                    'Name, picture and colour update for everyone in the party right away.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Divider(height: 1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    for (final (icon, label, trailing) in [
                      (
                        Icons.extension_outlined,
                        'Jellyfin & integrations',
                        '2 linked',
                      ),
                      (Icons.settings_outlined, 'Settings', null),
                      (Icons.system_update_alt, 'Update to 0.3.0', 'new'),
                      (Icons.info_outline, 'About', null),
                    ])
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                        ),
                        leading: Icon(icon, size: 20),
                        title: Text(label),
                        trailing: trailing == null
                            ? null
                            : trailing == 'new'
                            ? const _Pill('new', Colors.greenAccent)
                            : Text(
                                trailing,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                        onTap: () {},
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Avatar crop: pick a file, drag to move, scroll or slide to zoom; live
/// previews at the sizes it is shown. "Use this" renders a 256 px PNG.
class _CropPicker extends StatefulWidget {
  const _CropPicker();

  @override
  State<_CropPicker> createState() => _CropPickerState();
}

class _CropPickerState extends State<_CropPicker> {
  static const _view = 300.0, _out = 256;
  ui.Image? _img;
  double _zoom = 1; // 1 = the image just covers the circle
  Offset _pan = Offset.zero; // in viewport pixels
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Straight to the file dialog: that's why the picker was opened.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: 'Pick a picture',
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      );
    } catch (e) {
      setState(() => _error = 'file dialog unavailable: $e');
      return;
    }
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    try {
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      _img?.dispose();
      setState(() {
        _img = frame.image;
        _zoom = 1;
        _pan = Offset.zero;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'could not read that image');
    }
  }

  double get _scale {
    final img = _img!;
    return math.max(_view / img.width, _view / img.height) * _zoom;
  }

  /// Keeps the circle covered: the image edge never shows inside it.
  Offset _clamp(Offset p) {
    final img = _img!;
    final mx = (img.width * _scale - _view) / 2,
        my = (img.height * _scale - _view) / 2;
    return Offset(p.dx.clamp(-mx, mx), p.dy.clamp(-my, my));
  }

  void _setZoom(double z) => setState(() {
    _zoom = z.clamp(1.0, 6.0);
    _pan = _clamp(_pan);
  });

  Future<void> _use() async {
    final img = _img;
    if (img == null) return;
    setState(() => _busy = true);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(_out / _view);
    _CropPainter(img, _scale, _pan).paint(canvas, const Size(_view, _view));
    final out = await rec.endRecording().toImage(_out, _out);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (!mounted || png == null) return;
    final bytes = png.buffer.asUint8List();
    _me.value = _me.value.copyWith(avatar: bytes);
    _avatarInfo.value =
        '${_out}x$_out PNG · ${(bytes.length / 1024).toStringAsFixed(0)} KB';
    Navigator.of(context).pop();
  }

  Widget _preview(double size) => ClipOval(
    child: SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CropPainter(
          _img!,
          _scale * size / _view,
          _pan * (size / _view),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = _img;
    final editor = img == null
        ? InkWell(
            customBorder: const CircleBorder(),
            onTap: _pick,
            child: Container(
              width: _view,
              height: _view,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHighest,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 48,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error ?? 'Choose a picture',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        : Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _setZoom(_zoom * (e.scrollDelta.dy > 0 ? 0.93 : 1.07));
              }
            },
            child: GestureDetector(
              onPanUpdate: (d) => setState(() => _pan = _clamp(_pan + d.delta)),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                // The dimmed surroundings stay inside this rounded square.
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    width: _view,
                    height: _view,
                    child: Stack(
                      children: [
                        // The whole image, dimmed outside the circle.
                        Positioned.fill(
                          child: Opacity(
                            opacity: 0.3,
                            child: CustomPaint(
                              painter: _CropPainter(
                                img,
                                _scale,
                                _pan,
                                clipToView: false,
                              ),
                            ),
                          ),
                        ),
                        ClipOval(
                          child: CustomPaint(
                            size: const Size(_view, _view),
                            painter: _CropPainter(img, _scale, _pan),
                          ),
                        ),
                        IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.primary,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
    return Material(
      elevation: 16,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Your picture',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                img == null
                    ? 'PNG, JPG, WebP, GIF or BMP'
                    : 'Drag to move · scroll to zoom',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  editor,
                  if (img != null) ...[
                    const SizedBox(width: 24),
                    Column(
                      children: [
                        _preview(88),
                        const SizedBox(height: 4),
                        const Text(
                          'profile',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const SizedBox(height: 14),
                        _preview(42),
                        const SizedBox(height: 4),
                        const Text(
                          'party',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const SizedBox(height: 14),
                        _preview(24),
                        const SizedBox(height: 4),
                        const Text(
                          'chat',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              if (img != null)
                Row(
                  children: [
                    const Icon(Icons.zoom_out, size: 18),
                    Expanded(
                      child: Slider(
                        value: _zoom,
                        min: 1,
                        max: 6,
                        onChanged: _setZoom,
                      ),
                    ),
                    const Icon(Icons.zoom_in, size: 18),
                  ],
                )
              else
                const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(img == null ? 'Choose…' : 'Other file…'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: img == null || _busy ? null : _use,
                    child: const Text('Use this'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws [img] scaled by [scale], centred in the box and moved by [pan].
class _CropPainter extends CustomPainter {
  final ui.Image img;
  final double scale;
  final Offset pan;
  final bool clipToView;
  _CropPainter(this.img, this.scale, this.pan, {this.clipToView = true});

  @override
  void paint(Canvas canvas, Size size) {
    if (clipToView) canvas.clipRect(Offset.zero & size);
    final w = img.width * scale, h = img.height * scale;
    final dst = Rect.fromLTWH(
      (size.width - w) / 2 + pan.dx,
      (size.height - h) / 2 + pan.dy,
      w,
      h,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.img != img || old.scale != scale || old.pan != pan;
}

/// Size of the last exported picture (shown under the profile avatar).
final _avatarInfo = ValueNotifier<String?>(null);

/// Horizontal lists for mouse users: drag with the mouse, and the plain
/// (vertical) wheel moves them sideways. At either end the wheel is left
/// to the page, so a row never traps vertical scrolling; lists inside
/// (schedule day columns) keep their own vertical wheel.
class _HScroll extends StatefulWidget {
  final ScrollController? controller;
  final Widget Function(ScrollController controller) builder;
  const _HScroll({this.controller, required this.builder});

  @override
  State<_HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<_HScroll> {
  ScrollController? _own;
  ScrollController get _c => widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy;
    if (dy == 0 || e.scrollDelta.dx != 0 || !_c.hasClients) return;
    final p = _c.position;
    final target = (p.pixels + dy * 1.5).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    if (target == p.pixels) return; // at the end: let the page scroll
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      _c.animateTo(
        target,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context)
        .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
    child: Listener(onPointerSignal: _wheel, child: widget.builder(_c)),
  );
}
