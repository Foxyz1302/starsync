// The player controls' user choices (Settings → Player, stored in
// `AppSettings`). Plain values: the layout spec and both skins read them.

/// The controls' look. Both skins draw the same controls model in the same
/// order ([ControlsLayout]); only the look differs.
enum ControlsSkin {
  /// Material-style bar: a seek bar over a row of round icon buttons.
  standard('Standard'),

  /// The app's own timeline skin (inspired by mpv's uosc): a thick band
  /// with the buffered part, chapters and times, flat glass buttons.
  minimal('Minimal');

  final String label;
  const ControlsSkin(this.label);

  /// A stored name; the old `mpvControls` flag (true: the uosc design)
  /// when there is none.
  static ControlsSkin fromStored(Object? name, {Object? legacyMpvControls}) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return legacyMpvControls == true ? minimal : standard;
  }
}

/// The bar's clock: "6:00 / 24:00" or the time left ("-18:00").
enum TimeDisplay {
  elapsed('Elapsed / total'),
  remaining('Remaining');

  final String label;
  const TimeDisplay(this.label);

  TimeDisplay get toggled => this == elapsed ? remaining : elapsed;
}

/// Bar and button size.
enum ControlsSize {
  normal('Normal', 1.0),
  large('Large', 1.25);

  final String label;
  final double scale;
  const ControlsSize(this.label, this.scale);
}

/// Bar buttons the user may hide; hidden ones are still in ⚙.
enum OptionalControl {
  chapters('Chapter buttons', 'Previous / next chapter (PgUp / PgDn)'),
  subtitles('Subtitles', 'The subtitle track list'),
  audio('Audio', 'The audio track list'),
  chat('Chat', 'Chat & activity (Tab)');

  final String label;
  final String help;
  const OptionalControl(this.label, this.help);
}

/// The auto-hide delays offered (seconds).
const controlsHideChoices = [2, 3, 5];

/// The default auto-hide delay (seconds).
const defaultControlsHideSecs = 3;
