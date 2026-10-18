import 'package:flutter/material.dart';

import '../shell/motion.dart' show ease, easeTime;

// The rows every setting is drawn with, in Settings and in the player
// panel: one widget per setting, the same label in both. Under a
// [SettingDensity] (the panel) the rows are dense: smaller type, the
// help as the label's tooltip plus an optional [SettingRow.brief] line,
// sliders with the label at their left.

/// Dense rows below (the player panel's narrow glass column).
class SettingDensity extends InheritedWidget {
  final bool dense;
  const SettingDensity({super.key, this.dense = true, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingDensity>()?.dense ?? false;

  @override
  bool updateShouldNotify(SettingDensity old) => old.dense != dense;
}

/// Dense type sizes and the muted colour of help lines.
abstract final class DenseText {
  static const label = TextStyle(fontSize: 13);
  static TextStyle help(BuildContext context) =>
      TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5));
}

/// One setting: a label, its help under it, the control at the right
/// ([below]: an extra line under the row, e.g. a text field). Dense: the
/// help is the label's tooltip and only [brief] shows under it.
class SettingRow extends StatelessWidget {
  final String label;
  final String? help;

  /// The line under the label in a dense row (the help is long for it).
  final String? brief;
  final Widget control;
  final Widget? below;
  const SettingRow({super.key, required this.label, this.help, this.brief, required this.control, this.below});

  @override
  Widget build(BuildContext context) {
    if (SettingDensity.of(context)) {
      final text = Text(label, style: DenseText.label);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(
                children: [
                  Expanded(
                    child: help == null
                        ? text
                        : Tooltip(message: help!, waitDuration: const Duration(milliseconds: 600), child: text),
                  ),
                  const SizedBox(width: 8),
                  // The control's own width, up to about half the row.
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 164), child: control),
                ],
              ),
            ),
            if (brief != null) Text(brief!, style: DenseText.help(context)),
            ?below,
          ],
        ),
      );
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    if (help != null) Text(help!, style: TextStyle(color: muted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              control,
            ],
          ),
          ?below,
        ],
      ),
    );
  }
}

/// A setting that is on or off.
class SettingSwitch extends StatelessWidget {
  final String label;
  final String? help;
  final String? brief;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// The switch's key.
  final Key? switchKey;
  const SettingSwitch({
    super.key,
    required this.label,
    this.help,
    this.brief,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  @override
  Widget build(BuildContext context) {
    final control = Switch(key: switchKey, value: value, onChanged: onChanged);
    return SettingRow(
      label: label,
      help: help,
      brief: brief,
      control: SettingDensity.of(context)
          ? Transform.scale(scale: 0.8, alignment: Alignment.centerRight, child: control)
          : control,
    );
  }
}

/// A setting on a track ([track]: a [Slider] or the volume bar), with
/// its readout at the right. Dense: label, track and readout on one line.
class SettingTrack extends StatelessWidget {
  final String label;
  final String? help;
  final String? brief;
  final String readout;
  final Color? readoutColor;
  final Widget track;
  const SettingTrack({
    super.key,
    required this.label,
    this.help,
    this.brief,
    required this.readout,
    this.readoutColor,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    final dense = SettingDensity.of(context);
    final scheme = Theme.of(context).colorScheme;
    final value = SizedBox(
      width: 52,
      child: Text(
        readout,
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: dense ? 12 : 13,
          color: readoutColor ?? (dense ? scheme.onSurface.withValues(alpha: 0.7) : null),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final compact = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: track,
    );
    if (!dense) {
      return SettingRow(
        label: label,
        help: help,
        control: SizedBox(width: 260, child: Row(children: [Expanded(child: compact), value])),
      );
    }
    final text = Text(label, style: DenseText.label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: help == null
                      ? text
                      : Tooltip(message: help!, waitDuration: const Duration(milliseconds: 600), child: text),
                ),
                Expanded(child: compact),
                value,
              ],
            ),
          ),
          if (brief != null) Text(brief!, style: DenseText.help(context)),
        ],
      ),
    );
  }
}

/// A group of rows folded under "More" (Settings) or a smaller title
/// (the panel's Troubleshooting): closed at first; its title toggles it.
class SettingFold extends StatefulWidget {
  final String title;
  final List<Widget> children;
  final bool initiallyOpen;
  const SettingFold({super.key, this.title = 'More', required this.children, this.initiallyOpen = false});

  @override
  State<SettingFold> createState() => _SettingFoldState();
}

class _SettingFoldState extends State<SettingFold> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final dense = SettingDensity.of(context);
    final muted = dense
        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('fold-${widget.title}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: dense ? 6 : 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0 : -0.25,
                  duration: easeTime,
                  curve: ease,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: muted),
                ),
                const SizedBox(width: 6),
                Text(widget.title, style: TextStyle(fontSize: dense ? 12.5 : 13, color: muted)),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: easeTime,
          curve: ease,
          alignment: Alignment.topCenter,
          child: _open
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
