import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../playback/playback_controller.dart';
import '../state/settings.dart';
import 'shader_presets.dart';

/// A shader pick from the menu; a null quality keeps the saved one.
typedef ShaderPick = (ShaderPreset, ShaderQuality?);

/// Compact shader button for the video controls bar (normal and
/// fullscreen). Opens a small menu: Off, the six Anime4K modes with
/// HQ / Fast, Custom. The menu is a route, so it outlives the controls
/// bar hiding under it; [onPick] runs on the caller's side.
class ShaderControlButton extends StatelessWidget {
  final FocusNode focusNode;
  final ReadonlySignal<RenderMode> renderMode;
  final void Function(ShaderPreset preset, ShaderQuality? quality) onPick;
  final ValueChanged<bool>? onMenuOpen;
  const ShaderControlButton({
    super.key,
    required this.focusNode,
    required this.renderMode,
    required this.onPick,
    this.onMenuOpen,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final quality = s.shaderQuality.value;
      final short = shaderShortLabel(preset, quality) ?? 'Shaders';
      return Tooltip(
        message: 'Video shaders (Ctrl+1..6, Ctrl+0 off)',
        child: TextButton.icon(
          focusNode: focusNode,
          style: TextButton.styleFrom(
            foregroundColor:
                preset == ShaderPreset.off ? Colors.white : Colors.amberAccent,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => showShaderMenu(context,
              renderMode: renderMode, onPick: onPick, onMenuOpen: onMenuOpen),
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: Text(short, style: const TextStyle(fontSize: 12)),
        ),
      );
    });
  }
}

/// "A HQ", "C+A Fast", "Custom"; null when shaders are off.
String? shaderShortLabel(ShaderPreset preset, ShaderQuality quality) =>
    switch (preset) {
      ShaderPreset.off => null,
      ShaderPreset.custom => 'Custom',
      _ => '${preset.label.replaceFirst('Mode ', '')} ${quality.label}',
    };

/// The shader menu, anchored on [context]'s box (the button that opens
/// it): Off, the six Anime4K modes with HQ / Fast, Custom.
Future<void> showShaderMenu(
  BuildContext context, {
  required ReadonlySignal<RenderMode> renderMode,
  required void Function(ShaderPreset preset, ShaderQuality? quality) onPick,
  ValueChanged<bool>? onMenuOpen,
}) async {
  final s = AppSettings.instance;
  final preset = s.shaderPreset.peek();
  final quality = s.shaderQuality.peek();
  final hasCustom = s.customShaders.peek().isNotEmpty;
  final button = context.findRenderObject() as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero),
          ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
  final software = renderMode.peek() == RenderMode.software;
  onMenuOpen?.call(true);
  final pick = await showMenu<ShaderPick>(
    context: context,
    position: position,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    // Wider than Material's 280 px cap: the mode rows hold two chips.
    constraints: const BoxConstraints(minWidth: 340, maxWidth: 340),
    items: [
      if (software)
        const PopupMenuItem(
          enabled: false,
          height: 32,
          child: Text('Software rendering: shaders have no effect',
              style: TextStyle(fontSize: 12, color: Colors.orange)),
        ),
      CheckedPopupMenuItem(
        value: (ShaderPreset.off, null),
        checked: preset == ShaderPreset.off,
        height: 36,
        child: const _Row(label: 'Off', keys: 'Ctrl+0'),
      ),
      for (final (i, mode) in ShaderPreset.modes.indexed)
        _ModeEntry(
          mode: mode,
          keys: 'Ctrl+${i + 1}',
          current: preset == mode ? quality : null,
        ),
      CheckedPopupMenuItem(
        value: (ShaderPreset.custom, null),
        checked: preset == ShaderPreset.custom,
        enabled: hasCustom,
        height: 36,
        child: Text(hasCustom
            ? 'Custom shaders'
            : 'Custom shaders (pick files in Settings)'),
      ),
    ],
  );
  onMenuOpen?.call(false);
  if (pick != null) onPick(pick.$1, pick.$2);
}

class _Row extends StatelessWidget {
  final String label;
  final String keys;
  const _Row({required this.label, required this.keys});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(keys, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

/// One Anime4K mode: the row picks it with the saved quality, the two
/// chips pick a quality explicitly.
class _ModeEntry extends PopupMenuEntry<ShaderPick> {
  final ShaderPreset mode;
  final String keys;
  /// The active quality when this mode is the current one.
  final ShaderQuality? current;
  const _ModeEntry({
    required this.mode,
    required this.keys,
    required this.current,
  });

  @override
  double get height => 36;

  @override
  bool represents(ShaderPick? value) => value?.$1 == mode;

  @override
  State<_ModeEntry> createState() => _ModeEntryState();
}

class _ModeEntryState extends State<_ModeEntry> {
  @override
  Widget build(BuildContext context) {
    final w = widget;
    final theme = Theme.of(context);
    void pick(ShaderQuality? q) => Navigator.of(context).pop((w.mode, q));
    return InkWell(
      onTap: () => pick(null),
      child: Container(
        height: w.height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: w.current != null
                  ? Icon(Icons.done, size: 20, color: theme.colorScheme.primary)
                  : null,
            ),
            SizedBox(width: 96, child: Text(w.mode.label)),
            for (final q in ShaderQuality.values)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  label: Text(q.label, style: const TextStyle(fontSize: 11)),
                  selected: w.current == q,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  onSelected: (_) => pick(q),
                ),
              ),
            const Spacer(),
            Text(w.keys,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
