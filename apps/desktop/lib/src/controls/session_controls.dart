import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../state/settings.dart';
import 'controls_probe.dart' show ControlsHold;
import 'frame.dart';
import 'minimal/minimal_controls.dart';
import 'model/controls_model.dart';
import 'model/controls_prefs.dart';
import 'standard/standard_controls.dart';

// The session's controls: one [ControlsFrame] (when they are up) around the
// skin the settings pick, both drawing the same [PlayerControlsModel].
// Skin, size and the hide delay follow the settings live.

/// The bottom controls' height in [skin] at [size] (the player's floating
/// pills sit just above it).
double controlsBottomHeight(ControlsSkin skin, ControlsSize size) => switch (skin) {
  ControlsSkin.standard => StandardControls.bottomHeight(size.scale),
  ControlsSkin.minimal => MinimalControls.bottomHeight(size.scale),
};

/// The top bar's height in [skin].
double controlsTopHeight(ControlsSkin skin) => switch (skin) {
  ControlsSkin.standard => StandardControls.topHeight,
  ControlsSkin.minimal => MinimalControls.topHeight,
};

class SessionControls extends StatelessWidget {
  final PlayerControlsModel model;

  /// Follows whether the controls are up.
  final ValueNotifier<bool> shown;
  final ControlsHold hold;
  final VoidCallback onDoubleClick;
  final Widget? windowButtons;
  const SessionControls({
    super.key,
    required this.model,
    required this.shown,
    required this.hold,
    required this.onDoubleClick,
    this.windowButtons,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) {
        final skin = s.controlsSkin.value;
        final size = s.controlsSize.value;
        final scale = size.scale;
        return ControlsFrame(
          // A new frame per skin: each starts up, like a fresh mount.
          key: ValueKey(skin),
          shown: shown,
          holdBy: hold,
          hideAfter: Duration(seconds: s.controlsHideSecs.value),
          onDoubleClick: onDoubleClick,
          barTop: controlsTopHeight(skin),
          barBottom: controlsBottomHeight(skin, size),
          builder: (context, visible) => switch (skin) {
            ControlsSkin.standard => StandardControls(
              model: model,
              visible: visible,
              scale: scale,
              hold: hold,
              windowButtons: windowButtons,
            ),
            ControlsSkin.minimal => MinimalControls(
              model: model,
              visible: visible,
              scale: scale,
              hold: hold,
              windowButtons: windowButtons,
            ),
          },
        );
      },
    );
  }
}
