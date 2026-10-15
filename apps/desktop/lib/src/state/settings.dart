import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';

import '../controls/model/controls_prefs.dart';
import '../shaders/shader_presets.dart';
import 'settings_schema.dart';

// App preferences (Settings page), one Hive box. Signals start at their
// defaults and take the stored values once [AppSettings.ensureLoaded]
// finishes; setters write through.

const settingsBoxName = 'settings';

const _keyHwdecMode = 'hwdecMode';
const _keyHwdecCustom = 'hwdecCustom';
const _keyAutoCheckUpdates = 'autoCheckUpdates';
const _keyShaderPreset = 'shaderPreset';
const _keyShaderQuality = 'shaderQuality';
const _keyCustomShaders = 'customShaders';
const _keyAutoAdvance = 'autoAdvance';
/// Legacy: true was the uosc design (now [ControlsSkin.minimal]); read
/// once when [_keyControlsSkin] is missing.
const _keyMpvControls = 'mpvControls';
const _keyControlsSkin = 'controlsSkin';
const _keyTimeDisplay = 'timeDisplay';
const _keyControlsSize = 'controlsSize';
const _keyControlsHideSecs = 'controlsHideSecs';
const _keyHiddenControls = 'hiddenControls';
const _keyHideReReleases = 'hideReReleases';
const _keyProgressLine = 'progressLine';
const _keySoundVolume = 'soundVolume';
const _keySoundsOff = 'soundsOff';
const _keySoundPreset = 'soundPreset';
const _keyWelcomeDismissed = 'welcomeDismissed';
const _keySoundPresetFor = 'soundPresetFor';
const _keyUnreadyOnSwap = 'unreadyOnSwap';
const keyAutoSitOut = 'autoSitOut';
const _keyChatPopups = 'chatPopups';
const _keyShareDiagnostics = 'shareDiagnostics';

enum HwdecMode { auto, off, custom }

/// The mpv `hwdec` of [HwdecMode.auto]. Windows: 'auto-copy' (decoded on
/// the GPU, frames copied back): media_kit renders through ANGLE, where
/// plain 'auto' picks the dxva2 interop, which cannot create its EGL
/// surface there ("Failed to create EGL surface"). Elsewhere 'auto'.
String get autoHwdec => Platform.isWindows ? 'auto-copy' : 'auto';

/// When chat messages pop up as toasts (they always reach the chat).
enum ChatPopups {
  all('All'),
  paused('Only when paused'),
  off('Off');

  final String label;
  const ChatPopups(this.label);

  /// Whether a chat message pops up now ([playing]: the video plays).
  bool shows({required bool playing}) => switch (this) {
        ChatPopups.all => true,
        ChatPopups.paused => !playing,
        ChatPopups.off => false,
      };
}

class AppSettings {
  static final AppSettings instance = AppSettings();

  final hwdecMode = signal(HwdecMode.auto);
  final hwdecCustom = signal('');
  final autoCheckUpdates = signal(true);
  /// Jellyfin episodes: at the end, count down 10 s and put up the next.
  final autoAdvance = signal(true);
  /// Session: send ready=false when the video changes (a swap keeps the
  /// server's ready flags).
  final unreadyOnSwap = signal(false);
  /// Session: auto sit-out (idle while nothing plays, or minimised for a
  /// while, sets you away; coming back sets you in).
  final autoSitOut = signal(true);
  /// The player controls' skin (`controls/`). Applies live.
  final controlsSkin = signal(ControlsSkin.standard);
  /// The bar's clock: elapsed / total or the time left.
  final timeDisplay = signal(TimeDisplay.elapsed);
  final controlsSize = signal(ControlsSize.normal);
  /// Seconds without mouse movement before the controls hide.
  final controlsHideSecs = signal(defaultControlsHideSecs);
  /// Optional bar buttons switched off (they stay in ⚙).
  final hiddenControls = signal<Set<OptionalControl>>(const {});
  /// Library: leave out of "Latest in X" what was added long after it
  /// first aired (re-uploads, old seasons added late).
  final hideReReleases = signal(true);
  /// A 2 px progress line at the bottom of the video while the controls
  /// are hidden (both skins). Applies live.
  final progressLine = signal(true);
  /// Send this app's log lines to the server's session log while in a
  /// session (never chat). Off: nothing is sent but a note that it is off.
  final shareDiagnostics = signal(true);
  /// Chat message toasts (default: all). Applies live.
  final chatPopups = signal(ChatPopups.all);
  /// App sounds (`sfx/`): 0..1, 0 = silent.
  final soundVolume = signal(1.0);
  /// `SfxKind` names switched off one by one.
  final soundsOff = signal<Set<String>>(const {});
  /// The sound set (`SoundPreset` name) every sound uses unless
  /// [soundPresetFor] picks another one for it.
  final soundPreset = signal('cosmic');
  /// The offline welcome band's × was pressed: never show it again.
  final welcomeDismissed = signal(false);
  /// `SfxKind` name -> `SoundPreset` name, per-sound overrides.
  final soundPresetFor = signal<Map<String, String>>(const {});

  /// Video shaders: one choice, used on join and changed both here and
  /// in the session (Ctrl+0..6, the shader button).
  final shaderPreset = signal(ShaderPreset.off);
  final shaderQuality = signal(ShaderQuality.hq);
  /// .glsl files of [ShaderPreset.custom], in mpv order.
  final customShaders = signal<List<String>>(const []);

  /// mpv `hwdec` value: [autoHwdec], 'no', or the custom value
  /// ([autoHwdec] when custom is blank).
  late final hwdec = computed(() => switch (hwdecMode.value) {
        HwdecMode.auto => autoHwdec,
        HwdecMode.off => 'no',
        HwdecMode.custom =>
          hwdecCustom.value.trim().isEmpty ? autoHwdec : hwdecCustom.value.trim(),
      });

  Future<void>? _load;
  Box? _box;

  Future<void> ensureLoaded() => _load ??= _loadNow();

  Future<void> _loadNow() async {
    try {
      final box = _box = await Hive.openBox(settingsBoxName);
      for (final line in await migrateSettings(box)) {
        debugPrint(line);
      }
      final mode = box.get(_keyHwdecMode);
      hwdecMode.value = HwdecMode.values
              .where((m) => m.name == mode)
              .firstOrNull ??
          HwdecMode.auto;
      final custom = box.get(_keyHwdecCustom);
      if (custom is String) hwdecCustom.value = custom;
      final auto = box.get(_keyAutoCheckUpdates);
      if (auto is bool) autoCheckUpdates.value = auto;
      final advance = box.get(_keyAutoAdvance);
      if (advance is bool) autoAdvance.value = advance;
      final unready = box.get(_keyUnreadyOnSwap);
      if (unready is bool) unreadyOnSwap.value = unready;
      final autoOut = box.get(keyAutoSitOut);
      if (autoOut is bool) autoSitOut.value = autoOut;
      controlsSkin.value =
          ControlsSkin.fromStored(box.get(_keyControlsSkin), legacyMpvControls: box.get(_keyMpvControls));
      final time = box.get(_keyTimeDisplay);
      timeDisplay.value = TimeDisplay.values.where((t) => t.name == time).firstOrNull ?? TimeDisplay.elapsed;
      final size = box.get(_keyControlsSize);
      controlsSize.value = ControlsSize.values.where((t) => t.name == size).firstOrNull ?? ControlsSize.normal;
      final hide = box.get(_keyControlsHideSecs);
      if (hide is int && controlsHideChoices.contains(hide)) controlsHideSecs.value = hide;
      final hidden = box.get(_keyHiddenControls);
      if (hidden is List) {
        hiddenControls.value = Set.unmodifiable(OptionalControl.values.where((c) => hidden.contains(c.name)));
      }
      final hideRe = box.get(_keyHideReReleases);
      if (hideRe is bool) hideReReleases.value = hideRe;
      final line = box.get(_keyProgressLine);
      if (line is bool) progressLine.value = line;
      final share = box.get(_keyShareDiagnostics);
      if (share is bool) shareDiagnostics.value = share;
      final popups = box.get(_keyChatPopups);
      chatPopups.value = ChatPopups.values.where((m) => m.name == popups).firstOrNull ?? ChatPopups.all;
      final vol = box.get(_keySoundVolume);
      if (vol is num) soundVolume.value = vol.toDouble().clamp(0, 1);
      final off = box.get(_keySoundsOff);
      if (off is List) soundsOff.value = Set.unmodifiable(off.whereType<String>());
      final welcomeOff = box.get(_keyWelcomeDismissed);
      if (welcomeOff is bool) welcomeDismissed.value = welcomeOff;
      final soundSet = box.get(_keySoundPreset);
      if (soundSet is String) soundPreset.value = soundSet;
      final per = box.get(_keySoundPresetFor);
      if (per is Map) {
        soundPresetFor.value = Map.unmodifiable({
          for (final e in per.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
        });
      }
      final preset = box.get(_keyShaderPreset);
      shaderPreset.value =
          ShaderPreset.values.where((p) => p.name == preset).firstOrNull ??
              ShaderPreset.off;
      final quality = box.get(_keyShaderQuality);
      shaderQuality.value =
          ShaderQuality.values.where((q) => q.name == quality).firstOrNull ??
              ShaderQuality.hq;
      final files = box.get(_keyCustomShaders);
      if (files is List) {
        customShaders.value = List.unmodifiable(files.whereType<String>());
      }
    } catch (e, st) {
      debugPrint('load settings failed: $e\n$st');
    }
  }

  void setHwdecMode(HwdecMode mode) {
    hwdecMode.value = mode;
    _put(_keyHwdecMode, mode.name);
  }

  void setHwdecCustom(String value) {
    hwdecCustom.value = value;
    _put(_keyHwdecCustom, value);
  }

  void setAutoCheckUpdates(bool on) {
    autoCheckUpdates.value = on;
    _put(_keyAutoCheckUpdates, on);
  }

  void setAutoAdvance(bool on) {
    autoAdvance.value = on;
    _put(_keyAutoAdvance, on);
  }

  void setUnreadyOnSwap(bool on) {
    unreadyOnSwap.value = on;
    _put(_keyUnreadyOnSwap, on);
  }

  void setAutoSitOut(bool on) {
    autoSitOut.value = on;
    _put(keyAutoSitOut, on);
  }

  void setControlsSkin(ControlsSkin skin) {
    controlsSkin.value = skin;
    _put(_keyControlsSkin, skin.name);
  }

  void setTimeDisplay(TimeDisplay t) {
    timeDisplay.value = t;
    _put(_keyTimeDisplay, t.name);
  }

  void setControlsSize(ControlsSize size) {
    controlsSize.value = size;
    _put(_keyControlsSize, size.name);
  }

  void setControlsHideSecs(int secs) {
    controlsHideSecs.value = secs;
    _put(_keyControlsHideSecs, secs);
  }

  void setControlShown(OptionalControl c, bool on) {
    final next = {...hiddenControls.value};
    on ? next.remove(c) : next.add(c);
    hiddenControls.value = Set.unmodifiable(next);
    _put(_keyHiddenControls, [for (final c in next) c.name]);
  }

  void setProgressLine(bool on) {
    progressLine.value = on;
    _put(_keyProgressLine, on);
  }

  void setShareDiagnostics(bool on) {
    shareDiagnostics.value = on;
    _put(_keyShareDiagnostics, on);
  }

  void setChatPopups(ChatPopups mode) {
    chatPopups.value = mode;
    _put(_keyChatPopups, mode.name);
  }

  void setSoundVolume(double v) {
    soundVolume.value = v.clamp(0, 1);
    _put(_keySoundVolume, soundVolume.value);
  }

  void setSoundOn(String kind, bool on) {
    soundsOff.value = Set.unmodifiable(on ? ({...soundsOff.value}..remove(kind)) : {...soundsOff.value, kind});
    _put(_keySoundsOff, soundsOff.value.toList());
  }

  void dismissWelcome() {
    welcomeDismissed.value = true;
    _put(_keyWelcomeDismissed, true);
  }

  void setSoundPreset(String preset) {
    soundPreset.value = preset;
    _put(_keySoundPreset, preset);
  }

  /// [preset] null: the sound follows [soundPreset] again.
  void setSoundPresetFor(String kind, String? preset) {
    final m = {...soundPresetFor.value};
    preset == null ? m.remove(kind) : m[kind] = preset;
    soundPresetFor.value = Map.unmodifiable(m);
    _put(_keySoundPresetFor, m);
  }

  void setHideReReleases(bool on) {
    hideReReleases.value = on;
    _put(_keyHideReReleases, on);
  }

  void setShaderPreset(ShaderPreset preset) {
    shaderPreset.value = preset;
    _put(_keyShaderPreset, preset.name);
  }

  void setShaderQuality(ShaderQuality quality) {
    shaderQuality.value = quality;
    _put(_keyShaderQuality, quality.name);
  }

  void setCustomShaders(List<String> paths) {
    customShaders.value = List.unmodifiable(paths);
    _put(_keyCustomShaders, [...paths]);
  }

  Future<void> _put(String key, Object value) async {
    try {
      final box = _box ??
          (Hive.isBoxOpen(settingsBoxName) ? Hive.box(settingsBoxName) : null);
      await box?.put(key, value);
    } catch (e, st) {
      debugPrint('save setting $key failed: $e\n$st');
    }
  }
}
