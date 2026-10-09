import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';

import '../shaders/shader_presets.dart';

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
const _keyMpvControls = 'mpvControls';
const _keyHideReReleases = 'hideReReleases';
const _keyProgressLine = 'progressLine';
const _keySoundVolume = 'soundVolume';
const _keySoundsOff = 'soundsOff';

enum HwdecMode { auto, off, custom }

class AppSettings {
  static final AppSettings instance = AppSettings();

  final hwdecMode = signal(HwdecMode.auto);
  final hwdecCustom = signal('');
  final autoCheckUpdates = signal(true);
  /// Jellyfin episodes: at the end, count down 10 s and put up the next.
  final autoAdvance = signal(true);
  /// Player design: the uosc controls (`controls/uosc/`) instead of the
  /// standard ones (media_kit's with our bars). Applies live.
  final mpvControls = signal(false);
  /// Library: leave out of "Latest in X" what was added long after it
  /// first aired (re-uploads, old seasons added late).
  final hideReReleases = signal(true);
  /// A 2 px progress line at the bottom of the video while the controls
  /// are hidden (both designs). Applies live.
  final progressLine = signal(true);
  /// App sounds (`sfx/`): 0..1, 0 = silent.
  final soundVolume = signal(0.5);
  /// `SfxKind` names switched off one by one.
  final soundsOff = signal<Set<String>>(const {});

  /// Video shaders: one choice, used on join and changed both here and
  /// in the session (Ctrl+0..6, the shader button).
  final shaderPreset = signal(ShaderPreset.off);
  final shaderQuality = signal(ShaderQuality.hq);
  /// .glsl files of [ShaderPreset.custom], in mpv order.
  final customShaders = signal<List<String>>(const []);

  /// mpv `hwdec` value: 'auto', 'no', or the custom value ('auto' when
  /// custom is blank).
  late final hwdec = computed(() => switch (hwdecMode.value) {
        HwdecMode.auto => 'auto',
        HwdecMode.off => 'no',
        HwdecMode.custom =>
          hwdecCustom.value.trim().isEmpty ? 'auto' : hwdecCustom.value.trim(),
      });

  Future<void>? _load;
  Box? _box;

  Future<void> ensureLoaded() => _load ??= _loadNow();

  Future<void> _loadNow() async {
    try {
      final box = _box = await Hive.openBox(settingsBoxName);
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
      final mpv = box.get(_keyMpvControls);
      if (mpv is bool) mpvControls.value = mpv;
      final hideRe = box.get(_keyHideReReleases);
      if (hideRe is bool) hideReReleases.value = hideRe;
      final line = box.get(_keyProgressLine);
      if (line is bool) progressLine.value = line;
      final vol = box.get(_keySoundVolume);
      if (vol is num) soundVolume.value = vol.toDouble().clamp(0, 1);
      final off = box.get(_keySoundsOff);
      if (off is List) soundsOff.value = Set.unmodifiable(off.whereType<String>());
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

  void setMpvControls(bool on) {
    mpvControls.value = on;
    _put(_keyMpvControls, on);
  }

  void setProgressLine(bool on) {
    progressLine.value = on;
    _put(_keyProgressLine, on);
  }

  void setSoundVolume(double v) {
    soundVolume.value = v.clamp(0, 1);
    _put(_keySoundVolume, soundVolume.value);
  }

  void setSoundOn(String kind, bool on) {
    soundsOff.value = Set.unmodifiable(on ? ({...soundsOff.value}..remove(kind)) : {...soundsOff.value, kind});
    _put(_keySoundsOff, soundsOff.value.toList());
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
