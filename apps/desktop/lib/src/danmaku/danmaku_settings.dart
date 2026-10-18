import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../shell/avatar.dart' show AvatarInfo, colorForName, selfAvatarInfo;
import '../state/settings.dart';
import '../widgets/app_menu.dart' show AppSelect;
import 'danmaku.dart';
import 'danmaku_preview.dart' show DanmakuPreview, DanmakuStandIn, MockSubtitles;

// Settings → Notifications & sounds: how notifications show over the full
// player (Toasts or Danmaku) and every knob of the danmaku look, with a
// live preview strip. The player's side panel shows the style and the
// knobs too ([DanmakuKnobs]).

/// Names of the weights the boldness slider steps through.
const danmakuWeightNames = {
  400: 'Regular',
  500: 'Medium',
  600: 'Semibold',
  700: 'Bold',
  800: 'Extra bold',
  900: 'Black',
};

/// "Notifications: Toasts / Danmaku" ([AppSettings.notifyStyle]).
class NotifyStyleSelect extends StatelessWidget {
  final AppSettings settings;
  const NotifyStyleSelect({super.key, required this.settings});

  @override
  Widget build(BuildContext context) => SignalBuilder(
        builder: (context) => AppSelect<NotifyStyle>(
          key: const ValueKey('notify-style'),
          value: settings.notifyStyle.value,
          onChanged: settings.setNotifyStyle,
          items: [for (final m in NotifyStyle.values) (m, m.label)],
        ),
      );
}

/// The card: the style picker, the preview strip and the knobs.
class DanmakuSettingsPanel extends StatelessWidget {
  final AppSettings settings;
  const DanmakuSettingsPanel({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Notifications'),
                  Text(
                      'Danmaku: over the full player, chat, joins, leaves, Up next and "starting now" fly across '
                      'the top of the picture instead of popping up. Problems and errors stay pop-ups, and so does '
                      'everything with the player small',
                      style: muted),
                ],
              ),
            ),
            const SizedBox(width: 12),
            NotifyStyleSelect(settings: settings),
          ],
        ),
        const SizedBox(height: 12),
        DanmakuPreviewStrip(settings: settings),
        const SizedBox(height: 6),
        DanmakuKnobs(settings: settings),
      ],
    );
  }
}

/// A 16:9-ish strip with a moving picture, a top sign and bottom
/// dialogue, and sample lines in the current look, a few a second.
class DanmakuPreviewStrip extends StatefulWidget {
  final AppSettings settings;
  final double height;
  const DanmakuPreviewStrip({super.key, required this.settings, this.height = 190});

  @override
  State<DanmakuPreviewStrip> createState() => _DanmakuPreviewStripState();
}

class _DanmakuPreviewStripState extends State<DanmakuPreviewStrip> {
  /// The strip plays this long after it opens or a knob moves, then
  /// rests (a click plays it again): a settings page left open costs
  /// nothing.
  static const playFor = Duration(seconds: 16);
  final _controller = DanmakuController();
  final _rng = math.Random(3);
  Timer? _timer;
  Timer? _rest;
  bool _playing = false;
  int _n = 0;
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    _stop = effect(() {
      widget.settings.danmakuStyle.value;
      untracked(_play);
    });
  }

  @override
  void dispose() {
    _stop();
    _timer?.cancel();
    _rest?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _play() {
    _rest?.cancel();
    _rest = Timer(playFor, () {
      _timer?.cancel();
      _timer = null;
      if (mounted) setState(() => _playing = false);
    });
    if (_timer != null) return;
    _send();
    _timer = Timer.periodic(const Duration(milliseconds: 1100), (_) => _send());
    if (_playing) return;
    _playing = true;
    if (_built && mounted) setState(() {});
  }

  bool _built = false;

  void _send() {
    final i = _n++;
    if (i % 7 == 3) {
      final me = selfAvatarInfo();
      _controller.add(DanmakuItem(
          kind: DanmakuKind.chat, sender: me.name, senderColor: me.color, text: 'this is my line', own: true, avatar: me));
      return;
    }
    final name = DanmakuPreview.sampleNames[_rng.nextInt(DanmakuPreview.sampleNames.length)];
    final who = AvatarInfo(name: name, color: colorForName(name));
    if (i % 9 == 5) {
      _controller.add(DanmakuItem(kind: DanmakuKind.join, sender: name, senderColor: who.color, text: 'joined', avatar: who));
      return;
    }
    // Short and medium lines: the long ones crowd a small strip.
    final pool = [for (final t in DanmakuPreview.sampleChat) if (t.length < 48) t];
    _controller.add(DanmakuItem(
        kind: DanmakuKind.chat,
        sender: name,
        senderColor: who.color,
        text: pool[_rng.nextInt(pool.length)],
        avatar: who));
  }

  @override
  Widget build(BuildContext context) {
    _built = true;
    final accent = Theme.of(context).colorScheme.primary;
    return ClipRRect(
      key: const ValueKey('danmaku-preview-strip'),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DanmakuStandIn(animate: _playing),
            const MockSubtitles(top: true, bottom: true),
            SignalBuilder(
              builder: (context) =>
                  DanmakuLayer(controller: _controller, style: widget.settings.danmakuStyle.value, accent: accent),
            ),
            Center(
              child: AnimatedOpacity(
                opacity: _playing ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: _playing,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('danmaku-preview-play'),
                    onPressed: _play,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Play preview'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every knob of the danmaku look, live and saved: crossing time, how
/// many at once, the lane band, opacity, size, boldness, outline,
/// avatars, your own lines framed; and a reset.
class DanmakuKnobs extends StatelessWidget {
  final AppSettings settings;

  /// Narrow (the player's side panel): shorter labels column.
  final bool dense;
  const DanmakuKnobs({super.key, required this.settings, this.dense = false});

  void _set(DanmakuStyle Function(DanmakuStyle s) f) => settings.setDanmakuStyle(f(settings.danmakuStyle.peek()));

  @override
  Widget build(BuildContext context) {
    const l = DanmakuStyle.limits;
    return SignalBuilder(builder: (context) {
      final s = settings.danmakuStyle.value;
      final labelW = dense ? 84.0 : 150.0;
      Widget slider(String key, String label, double v, (num, num) r, String readout, ValueChanged<double> f,
              {int? divisions}) =>
          _Knob(
            label: label,
            labelWidth: labelW,
            readout: readout,
            child: Slider(
              key: ValueKey('danmaku-$key'),
              value: v.clamp(r.$1.toDouble(), r.$2.toDouble()),
              min: r.$1.toDouble(),
              max: r.$2.toDouble(),
              divisions: divisions,
              onChanged: f,
            ),
          );
      Widget toggle(String key, String label, bool v, ValueChanged<bool> f) => _Knob(
            label: label,
            labelWidth: double.infinity,
            child: Switch(key: ValueKey('danmaku-$key'), value: v, onChanged: f),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          slider('cross', dense ? 'Crossing' : 'Crossing time', s.crossSecs, l.crossSecs,
              '${s.crossSecs.toStringAsFixed(1)} s', (v) => _set((s) => s.copyWith(crossSecs: v))),
          slider('cap', dense ? 'At most' : 'At most on screen', s.maxOnScreen.toDouble(), l.maxOnScreen,
              '${s.maxOnScreen} lines', (v) => _set((s) => s.copyWith(maxOnScreen: v.round())),
              divisions: l.maxOnScreen.$2 - l.maxOnScreen.$1),
          _Knob(
            label: dense ? 'Lanes' : 'Lanes (from the top)',
            labelWidth: labelW,
            readout: '${(s.bandTop * 100).round()}–${(s.bandBottom * 100).round()} %',
            child: RangeSlider(
              key: const ValueKey('danmaku-band'),
              values: RangeValues(s.bandTop, s.bandBottom),
              min: l.band.$1,
              max: l.band.$2,
              onChanged: (v) {
                if (v.end - v.start >= l.minBand) _set((s) => s.copyWith(bandTop: v.start, bandBottom: v.end));
              },
            ),
          ),
          slider('opacity', 'Opacity', s.opacity, l.opacity, '${(s.opacity * 100).round()} %',
              (v) => _set((s) => s.copyWith(opacity: v))),
          slider('size', 'Size', s.size, l.size, '×${s.size.toStringAsFixed(2)}', (v) => _set((s) => s.copyWith(size: v))),
          slider('weight', 'Boldness', s.weight.toDouble(), l.weight, danmakuWeightNames[s.weight] ?? '${s.weight}',
              (v) => _set((s) => s.copyWith(weight: (v / 100).round() * 100)),
              divisions: (l.weight.$2 - l.weight.$1) ~/ 100),
          slider('outline', 'Outline', s.outline, l.outline,
              s.outline < 0.05 ? 'none' : '${s.outline.toStringAsFixed(1)} px', (v) => _set((s) => s.copyWith(outline: v))),
          toggle('avatars', 'Avatars before the lines', s.avatars, (v) => _set((s) => s.copyWith(avatars: v))),
          toggle('own', 'Frame my own lines', s.highlightOwn, (v) => _set((s) => s.copyWith(highlightOwn: v))),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('danmaku-reset'),
              onPressed: s == const DanmakuStyle() ? null : () => settings.setDanmakuStyle(const DanmakuStyle()),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset look'),
            ),
          ),
        ],
      );
    });
  }
}

class _Knob extends StatelessWidget {
  final String label;
  final double labelWidth;
  final String? readout;
  final Widget child;
  const _Knob({required this.label, required this.labelWidth, this.readout, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Text(label, style: const TextStyle(fontSize: 13));
    if (labelWidth == double.infinity) {
      return SizedBox(
        height: 38,
        child: Row(children: [Expanded(child: text), Transform.scale(scale: 0.8, alignment: Alignment.centerRight, child: child)]),
      );
    }
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(width: labelWidth, child: text),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
                showValueIndicator: ShowValueIndicator.never,
                tickMarkShape: SliderTickMarkShape.noTickMark,
              ),
              child: child,
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              readout ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
