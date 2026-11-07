import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import '../controls/minimal/style.dart';
import '../controls/session_controls.dart' show controlsBottomHeight;
import '../session/notifier.dart' show ToastItem;
import '../session/session_coordinator.dart' show SessionCoordinator;
import '../shell/avatar.dart' show AvatarInfo, avatarForName, colorForName, memberAvatarInfo, selfAvatarInfo;
import '../shell/motion.dart';
import '../shell/quick_chat.dart';
import '../shell/video_view.dart' show SubtitleLift;
import '../app/app_graph.dart' show AppScope;
import '../widgets/app_menu.dart' show AppGlass, AppMenuStyle;
import 'danmaku.dart';
import 'danmaku_notices.dart' show danmakuForToast;

// Dev builds only (Settings → About → Developer): try the danmaku look on
// the real player (when something is loaded) or on a stand-in picture,
// fed with samples, a random stream or this session's own toasts, with
// every knob of [DanmakuStyle] live and mock subtitles to judge overlap.

/// The preview's state, owned by the shell while the app runs.
class DanmakuPreview {
  final controller = DanmakuController();

  /// Shown over the full session player.
  final active = signal(false);
  final Signal<DanmakuStyle> style;

  /// A random stream: lines per minute, lengths from one word to a long
  /// sentence, CJK and emoji among them.
  final auto = signal(false);
  final autoRate = signal(40.0);

  /// Mock subtitles: a top sign and bottom dialogue.
  final mockTop = signal(false);
  final mockBottom = signal(false);

  /// The stand-in picture's control band (the real player has its own).
  final controlsBand = signal(true);

  /// This session's chat and notice toasts fly too (session only).
  final live = signal(false);

  /// In a session: the party's real avatars for the samples and the
  /// session's toasts (set while the session panel is up).
  SessionCoordinator? coord;

  final _rng = math.Random();
  Timer? _autoTimer;
  late final void Function() _stopAuto;

  /// Starts from [style] (the user's look, Settings → Notifications &
  /// sounds); the preview's knobs change only the preview.
  DanmakuPreview({DanmakuStyle style = const DanmakuStyle()}) : style = signal(style) {
    _stopAuto = effect(() {
      final on = auto.value;
      autoRate.value;
      untracked(() {
        _autoTimer?.cancel();
        if (on) _scheduleAuto();
      });
    });
  }

  void dispose() {
    _stopAuto();
    _autoTimer?.cancel();
    controller.dispose();
  }

  void _scheduleAuto() {
    // Poisson arrivals: bursts and lulls like a real chat.
    final perSec = autoRate.peek() / 60;
    final wait = -math.log(1 - _rng.nextDouble()) / perSec;
    _autoTimer = Timer(Duration(milliseconds: (wait * 1000).round().clamp(30, 60000)), () {
      if (!auto.peek()) return;
      controller.add(randomSample());
      _scheduleAuto();
    });
  }

  /// One sample line of [kind]; [own]: as if this member wrote it.
  /// Senders come from the party in a session (their pictures), else
  /// from [sampleNames] (initials).
  DanmakuItem sample(DanmakuKind kind, {bool own = false}) {
    final a = own ? selfAvatarInfo() : _sampleSender();
    final who = a.name;
    final color = a.color;
    return switch (kind) {
      DanmakuKind.chat =>
        DanmakuItem(kind: kind, sender: who, senderColor: color, text: _pick(sampleChat), own: own, avatar: a),
      DanmakuKind.join => DanmakuItem(kind: kind, sender: who, senderColor: color, text: 'joined', avatar: a),
      DanmakuKind.leave => DanmakuItem(kind: kind, sender: who, senderColor: color, text: 'left', avatar: a),
      DanmakuKind.upNext => DanmakuItem(
          kind: kind, sender: who, senderColor: color, text: 'added ${_pick(sampleTitles)} to Up next', avatar: a),
      DanmakuKind.starting => const DanmakuItem(kind: DanmakuKind.starting, text: '▶  Starting now'),
    };
  }

  /// [text] as this member's own chat line.
  DanmakuItem own(String text) {
    final a = selfAvatarInfo();
    return DanmakuItem(kind: DanmakuKind.chat, sender: a.name, senderColor: a.color, text: text, own: true, avatar: a);
  }

  AvatarInfo _sampleSender() {
    final c = coord;
    final r = c?.serverState.peek();
    final others = [
      if (c != null && r != null)
        for (final m in r.members)
          if (m.id != c.connection.memberId) memberAvatarInfo(m, r, c),
    ];
    // The party's real ones half the time, so initials show up too.
    if (others.isNotEmpty && _rng.nextBool()) return _pick(others);
    final name = _pick(sampleNames);
    return AvatarInfo(name: name, color: colorForName(name));
  }

  /// What the random stream sends: mostly chat, some of it yours, now and
  /// then a notice.
  DanmakuItem randomSample() {
    final r = _rng.nextDouble();
    if (r < 0.70) return sample(DanmakuKind.chat);
    if (r < 0.80) return sample(DanmakuKind.chat, own: true);
    if (r < 0.88) return sample(DanmakuKind.join);
    if (r < 0.94) return sample(DanmakuKind.leave);
    return sample(DanmakuKind.upNext);
  }

  /// A toast of this session as a line, as "Notifications: Danmaku" maps
  /// it ([danmakuForToast]); the rest (problems) stay toasts.
  DanmakuItem? fromToast(ToastItem t) {
    final c = coord;
    return danmakuForToast(t, avatar: c == null ? null : (name, id) => avatarForName(name, c, id));
  }

  /// Follows [toasts] while [live] is on; returns the stop.
  void Function() watchToasts(ReadonlySignal<List<ToastItem>> toasts) {
    var seen = {for (final t in toasts.peek()) t.id};
    return effect(() {
      final items = toasts.value;
      final on = live.value;
      untracked(() {
        for (final t in items) {
          if (!seen.add(t.id) || !on) continue;
          final line = fromToast(t);
          if (line != null) controller.add(line);
        }
        seen = {for (final t in items) t.id};
      });
    });
  }

  T _pick<T>(List<T> from) => from[_rng.nextInt(from.length)];

  static const sampleNames = ['Alice', 'Bob', 'Chiyo', '小雪', 'Kenji', 'Mara'];
  static const sampleTitles = ['Frieren · 12', 'Bocchi the Rock! · 5', 'Dungeon Meshi · 20', 'Mob Psycho 100 · 3'];
  static const sampleChat = [
    'lol',
    'www',
    '草',
    '8888888',
    'NICE',
    'it\'s so over',
    'she\'s back!!',
    'wait, who is that?',
    'op skip pls 🙏',
    'the animation in this scene is insane',
    'I can\'t believe they actually adapted this arc, the manga panel looked exactly like this, chills honestly',
    'brb getting snacks, don\'t wait for me (actually do wait)',
    '前方高能预警！！！',
    'このシーン最高すぎる',
    '神回確定',
    '画质好清晰啊',
    '🔥🔥🔥',
    '😭😭 my heart',
    '🎉 finally',
    'Himmel would have done the same 🥲',
  ];
}

/// The danmaku with this preview's style and mock subtitles over a
/// picture; lets clicks through.
class DanmakuPreviewLayers extends StatelessWidget {
  final DanmakuPreview preview;

  /// The covered bottom the mock dialogue moves above, as the real
  /// subtitles do ([SubtitleLift]).
  final ValueListenable<double>? lift;
  const DanmakuPreviewLayers({super.key, required this.preview, this.lift});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SignalBuilder(
      builder: (context) => Stack(
        fit: StackFit.expand,
        children: [
          MockSubtitles(top: preview.mockTop.value, bottom: preview.mockBottom.value, lift: lift),
          DanmakuLayer(controller: preview.controller, style: preview.style.value, accent: accent),
        ],
      ),
    );
  }
}

/// Stand-ins for subtitles where real ones sit: an ASS sign at the top
/// (`\an8`, yellow serif) and two lines of dialogue at the bottom. The
/// dialogue moves up by [lift] (px covered at the bottom) in the same
/// steps as mpv's `sub-pos` moves the real ones; the sign stays.
class MockSubtitles extends StatelessWidget {
  final bool top;
  final bool bottom;
  final ValueListenable<double>? lift;
  const MockSubtitles({super.key, required this.top, required this.bottom, this.lift});

  static Widget _outlined(String text, TextStyle style, double outline) => Stack(
        children: [
          Text(text,
              textAlign: TextAlign.center,
              style: style.copyWith(
                color: null,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = outline
                  ..strokeJoin = StrokeJoin.round
                  ..color = const Color(0xFF1A1206),
              )),
          Text(text, textAlign: TextAlign.center, style: style),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (!top && !bottom) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        final h = box.maxHeight;
        final dialogue = (h * 0.05).clamp(12.0, 52.0);
        return Stack(
          children: [
            if (top)
              Positioned(
                left: 0,
                right: 0,
                top: h * 0.035,
                child: Center(
                  child: _outlined(
                    'TOP SIGN · 第3新東京市',
                    TextStyle(
                      fontSize: dialogue * 0.85,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFFFFE14D),
                    ),
                    dialogue * 0.14,
                  ),
                ),
              ),
            if (bottom)
              ValueListenableBuilder<double>(
                valueListenable: lift ?? const AlwaysStoppedAnimation(0.0),
                builder: (context, up, child) => Positioned(
                  key: const ValueKey('mock-dialogue'),
                  left: 0,
                  right: 0,
                  bottom: h * 0.05 + up,
                  child: child!,
                ),
                child: Center(
                  child: _outlined(
                    'I told you the controls would cover this line.\nThey never do now — or do they?',
                    TextStyle(fontSize: dialogue, height: 1.15, color: Colors.white, fontWeight: FontWeight.w500),
                    dialogue * 0.12,
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// A moving picture for the preview when nothing is loaded: slow colour
/// fields drifting over a dusk gradient, so motion and contrast behind
/// the lines are realistic.
class DanmakuStandIn extends StatefulWidget {
  /// False: a still picture (the settings' strip while it rests).
  final bool animate;
  const DanmakuStandIn({super.key, this.animate = true});

  @override
  State<DanmakuStandIn> createState() => _DanmakuStandInState();
}

class _DanmakuStandInState extends State<DanmakuStandIn> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 60));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _clock.repeat();
  }

  @override
  void didUpdateWidget(DanmakuStandIn old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_clock.isAnimating) _clock.repeat();
    if (!widget.animate && _clock.isAnimating) _clock.stop();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(painter: _StandInPainter(_clock), child: const SizedBox.expand()),
      );
}

class _StandInPainter extends CustomPainter {
  final Animation<double> clock;
  _StandInPainter(this.clock) : super(repaint: clock);

  static const _blobs = [
    (Color(0xFFFF7A59), 0.9, 0.0, 0.42),
    (Color(0xFF7C5CFF), 1.3, 1.7, 0.5),
    (Color(0xFF2EC5CE), 0.7, 3.1, 0.38),
    (Color(0xFFFFC857), 1.1, 4.4, 0.3),
    (Color(0xFFE85D9E), 0.5, 5.2, 0.45),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1030), Color(0xFF2A1B4A), Color(0xFF5A2F4F), Color(0xFF14141C)],
          stops: [0, 0.45, 0.72, 1],
        ).createShader(rect),
    );
    final t = clock.value * 2 * math.pi;
    final r = size.shortestSide;
    for (final (color, speed, phase, radius) in _blobs) {
      final c = Offset(
        size.width * (0.5 + 0.38 * math.sin(t * speed + phase)),
        size.height * (0.5 + 0.32 * math.cos(t * speed * 0.8 + phase * 1.3)),
      );
      canvas.drawCircle(
        c,
        r * radius,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r * radius)),
      );
    }
    // A bright horizon line and some stars: hard edges behind the text.
    final horizon = size.height * 0.68;
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, size.width, size.height - horizon),
      Paint()..color = const Color(0xCC0D0D14),
    );
    canvas.drawLine(Offset(0, horizon), Offset(size.width, horizon),
        Paint()
          ..color = const Color(0x88FFD7A8)
          ..strokeWidth = 1.5);
    final stars = math.Random(7);
    for (var i = 0; i < 90; i++) {
      final x = stars.nextDouble() * size.width;
      final y = stars.nextDouble() * horizon;
      final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * 8 + i));
      canvas.drawCircle(Offset(x, y), 0.6 + stars.nextDouble() * 1.2,
          Paint()..color = Colors.white.withValues(alpha: 0.5 * twinkle));
    }
  }

  @override
  bool shouldRepaint(_StandInPainter old) => false;
}

/// The preview's knobs on the app's glass: fire samples, the random
/// stream, the look, mock subtitles. [onClose] ends the preview; it
/// collapses to its title bar.
class DanmakuPanel extends StatefulWidget {
  final DanmakuPreview preview;
  final VoidCallback onClose;

  /// In a session: offer this session's own toasts as a source.
  final bool session;
  const DanmakuPanel({super.key, required this.preview, required this.onClose, this.session = false});

  @override
  State<DanmakuPanel> createState() => _DanmakuPanelState();
}

class _DanmakuPanelState extends State<DanmakuPanel> {
  bool _open = true;

  DanmakuPreview get p => widget.preview;

  void _style(DanmakuStyle Function(DanmakuStyle s) f) => p.style.value = f(p.style.peek());

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.6);
    return ExcludeFocus(
      child: AppGlass(
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Danmaku preview', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                    _Counts(controller: p.controller),
                    IconButton(
                      tooltip: _open ? 'Collapse' : 'Expand',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => setState(() => _open = !_open),
                      icon: AnimatedRotation(
                        turns: _open ? 0 : 0.5,
                        duration: easeTime,
                        curve: ease,
                        child: const Icon(Icons.expand_less),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close the preview',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: easeTime,
                curve: ease,
                alignment: Alignment.topCenter,
                child: !_open
                    ? const SizedBox(width: double.infinity)
                    : ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          child: SignalBuilder(builder: (context) => _body(muted)),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(Color muted) {
    final s = p.style.value;
    Widget fire(IconData icon, String label, DanmakuItem Function() item) => MinimalButton(
          icon: icon,
          label: label,
          tooltip: '',
          scale: 0.8,
          onPressed: () => p.controller.add(item()),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Head('Send', muted),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            fire(Icons.chat_bubble_outline, 'Chat', () => p.sample(DanmakuKind.chat)),
            fire(Icons.person_outline, 'Mine', () => p.sample(DanmakuKind.chat, own: true)),
            fire(Icons.login, 'Join', () => p.sample(DanmakuKind.join)),
            fire(Icons.logout, 'Leave', () => p.sample(DanmakuKind.leave)),
            fire(Icons.playlist_add_rounded, 'Up next', () => p.sample(DanmakuKind.upNext)),
            fire(Icons.play_arrow_rounded, 'Starting', () => p.sample(DanmakuKind.starting)),
            fire(Icons.bolt, 'Burst ×12', () {
              for (var i = 0; i < 11; i++) {
                p.controller.add(p.randomSample());
              }
              return p.randomSample();
            }),
            MinimalButton(
              icon: Icons.clear_all,
              label: 'Clear',
              tooltip: '',
              scale: 0.8,
              onPressed: p.controller.clear,
            ),
          ],
        ),
        _Toggle('Random stream', p.auto.value, (v) => p.auto.value = v),
        _Slider('Rate', p.autoRate.value, 5, 240, '${p.autoRate.value.round()}/min', (v) => p.autoRate.value = v,
            enabled: p.auto.value),
        if (widget.session) _Toggle("This session's chat and notices", p.live.value, (v) => p.live.value = v),
        _Head('Look', muted),
        _Slider('Crossing', s.crossSecs, 4, 16, '${s.crossSecs.toStringAsFixed(1)} s',
            (v) => _style((s) => s.copyWith(crossSecs: v))),
        _Slider('At most', s.maxOnScreen.toDouble(), 1, 40, '${s.maxOnScreen} lines',
            (v) => _style((s) => s.copyWith(maxOnScreen: v.round()))),
        _Range('Lanes', s.bandTop, s.bandBottom, '${(s.bandTop * 100).round()}–${(s.bandBottom * 100).round()} %',
            (a, b) => _style((s) => s.copyWith(bandTop: a, bandBottom: b))),
        _Slider('Opacity', s.opacity, 0.3, 1, '${(s.opacity * 100).round()} %',
            (v) => _style((s) => s.copyWith(opacity: v))),
        _Slider('Size', s.size, 0.6, 1.8, '×${s.size.toStringAsFixed(2)}', (v) => _style((s) => s.copyWith(size: v))),
        _Slider('Bold', s.weight.toDouble(), 400, 900, '${s.weight}',
            (v) => _style((s) => s.copyWith(weight: (v / 100).round() * 100))),
        _Slider('Outline', s.outline, 0, 4, '${s.outline.toStringAsFixed(1)} px',
            (v) => _style((s) => s.copyWith(outline: v))),
        _Toggle('Avatars', s.avatars, (v) => _style((s) => s.copyWith(avatars: v))),
        _Toggle('Frame my own lines', s.highlightOwn, (v) => _style((s) => s.copyWith(highlightOwn: v))),
        _Head('Subtitles (mock)', muted),
        _Toggle('Top sign', p.mockTop.value, (v) => p.mockTop.value = v),
        _Toggle('Bottom dialogue', p.mockBottom.value, (v) => p.mockBottom.value = v),
        if (!widget.session) _Toggle('Control bar', p.controlsBand.value, (v) => p.controlsBand.value = v),
      ],
    );
  }
}

class _Counts extends StatelessWidget {
  final DanmakuController controller;
  const _Counts({required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([controller.onScreen, controller.waiting]),
        builder: (context, _) => Tooltip(
          message: 'Flying · waiting for a lane',
          child: Text(
            '${controller.onScreen.value} · ${controller.waiting.value}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.6),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
}

class _Head extends StatelessWidget {
  final String text;
  final Color color;
  const _Head(this.text, this.color);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: color)),
      );
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 34,
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Transform.scale(scale: 0.75, alignment: Alignment.centerRight, child: Switch(value: value, onChanged: onChanged)),
          ],
        ),
      );
}

class _Slider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final String readout;
  final ValueChanged<double> onChanged;
  final bool enabled;
  const _Slider(this.label, this.value, this.min, this.max, this.readout, this.onChanged, {this.enabled = true});

  @override
  Widget build(BuildContext context) => _SliderFrame(
        label: label,
        readout: readout,
        child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: enabled ? onChanged : null),
      );
}

class _Range extends StatelessWidget {
  final String label;
  final double a, b;
  final String readout;
  final void Function(double a, double b) onChanged;
  const _Range(this.label, this.a, this.b, this.readout, this.onChanged);

  @override
  Widget build(BuildContext context) => _SliderFrame(
        label: label,
        readout: readout,
        child: RangeSlider(
          values: RangeValues(a, b),
          max: 0.9,
          onChanged: (v) {
            if (v.end - v.start >= 0.05) onChanged(v.start, v.end);
          },
        ),
      );
}

class _SliderFrame extends StatelessWidget {
  final String label;
  final String readout;
  final Widget child;
  const _SliderFrame({required this.label, required this.readout, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 34,
        child: Row(
          children: [
            SizedBox(width: 64, child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: child,
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                readout,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.7),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
}

/// The preview without a session player: the stand-in picture, a mock
/// control bar of the skin in use, the lines and the panel, over the
/// whole window (Esc or × closes it).
Future<void> showDanmakuPreviewPage(BuildContext context, DanmakuPreview preview) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Danmaku preview',
      barrierColor: Colors.black,
      transitionDuration: easeTime,
      pageBuilder: (context, _, _) => DanmakuPreviewPage(preview: preview),
      transitionBuilder: (context, anim, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: ease, reverseCurve: Curves.easeIn),
        child: child,
      ),
    );

class DanmakuPreviewPage extends StatefulWidget {
  final DanmakuPreview preview;
  const DanmakuPreviewPage({super.key, required this.preview});

  @override
  State<DanmakuPreviewPage> createState() => _DanmakuPreviewPageState();
}

/// The page also has the quick chat box (Enter): what you send flies as
/// your own line, and the mock dialogue moves above the box in the lift's
/// steps, as the real subtitles do over the player.
class _DanmakuPreviewPageState extends State<DanmakuPreviewPage> {
  final _chat = QuickChat();
  final _lift = SubtitleLift();
  final _pageFocus = FocusNode(debugLabel: 'danmaku preview');
  double _boxH = QuickChatBox.height;

  DanmakuPreview get preview => widget.preview;

  @override
  void initState() {
    super.initState();
    _chat.open.addListener(_retarget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pageFocus.requestFocus());
  }

  @override
  void dispose() {
    _chat.open.removeListener(_retarget);
    _chat.dispose();
    _lift.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  void _retarget() {
    final s = AppScope.of(context).coordinator.settings;
    final bar = preview.controlsBand.peek() && s.liftSubtitles.peek()
        ? controlsBottomHeight(s.controlsSkin.peek(), s.controlsSize.peek()) + 8
        : 0.0;
    final box = _chat.open.value ? 16 + _boxH + 8 : 0.0;
    _lift.animateTo(box > bar ? box : bar);
    if (!_chat.open.value) _pageFocus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _chat.show();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _pageFocus,
      onKeyEvent: _key,
      child: Material(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DanmakuStandIn(),
            DanmakuPreviewLayers(preview: preview, lift: _lift),
            SignalBuilder(builder: (context) {
              if (!preview.controlsBand.value) return const SizedBox.shrink();
              final s = AppScope.of(context).coordinator.settings;
              final h = controlsBottomHeight(s.controlsSkin.value, s.controlsSize.value);
              return Align(
                alignment: Alignment.bottomCenter,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _chat.open,
                    builder: (context, open, child) =>
                        AnimatedOpacity(opacity: open ? 0 : 1, duration: easeTime, curve: ease, child: child),
                    child: Container(
                      height: h,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), MinimalStyle.band],
                        ),
                        border: Border(top: BorderSide(color: AppMenuStyle.border, width: 0.5)),
                      ),
                      alignment: Alignment.center,
                      child: Text('control bar',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12)),
                    ),
                  ),
                ),
              );
            }),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: QuickChatBox(
                chat: _chat,
                onSend: (text) => preview.controller.add(preview.own(text)),
                onHeight: (h) {
                  _boxH = h;
                  if (_chat.open.value) _retarget();
                },
              ),
            ),
            Positioned(
              left: 16,
              top: 14,
              child: Text('Stand-in picture: load something to preview on the real player · Enter: chat box',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: DanmakuPanel(preview: preview, onClose: () => Navigator.of(context).pop()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel over the session player; while mounted, this session's
/// toasts reach the preview when its "chat and notices" switch is on.
class DanmakuSessionPanel extends StatefulWidget {
  final DanmakuPreview preview;
  final SessionCoordinator coord;
  const DanmakuSessionPanel({super.key, required this.preview, required this.coord});

  @override
  State<DanmakuSessionPanel> createState() => _DanmakuSessionPanelState();
}

class _DanmakuSessionPanelState extends State<DanmakuSessionPanel> {
  late final void Function() _stop = widget.preview.watchToasts(widget.coord.toasts);

  @override
  void initState() {
    super.initState();
    widget.preview.coord = widget.coord;
    _stop;
  }

  @override
  void dispose() {
    _stop();
    widget.preview.coord = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DanmakuPanel(
        preview: widget.preview,
        session: true,
        onClose: () => widget.preview.active.value = false,
      );
}
