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
const _keySoundPreset = 'soundPreset';
const _keyWelcomeDismissed = 'welcomeDismissed';
const _keySoundPresetFor = 'soundPresetFor';
const _keyUnreadyOnSwap = 'unreadyOnSwap';
const _keyIdleSitsOut = 'idleSitsOut';
const _keyChatPopups = 'chatPopups';

enum HwdecMode { auto, off, custom }

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
  /// Session: the idle auto-unready sits this member out instead.
  final idleSitsOut = signal(false);
  /// Player design: the uosc controls (`controls/uosc/`) instead of the
  /// standard ones (media_kit's with our bars). Applies live.
  final mpvControls = signal(false);
  /// Library: leave out of "Latest in X" what was added long after it
  /// first aired (re-uploads, old seasons added late).
  final hideReReleases = signal(true);
  /// A 2 px progress line at the bottom of the video while the controls
  /// are hidden (both designs). Applies live.
  final progressLine = signal(true);
  /// Chat message toasts (default: only when paused). Applies live.
  final chatPopups = signal(ChatPopups.paused);
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
      final unready = box.get(_keyUnreadyOnSwap);
      if (unready is bool) unreadyOnSwap.value = unready;
      final idleOut = box.get(_keyIdleSitsOut);
      if (idleOut is bool) idleSitsOut.value = idleOut;
      final mpv = box.get(_keyMpvControls);
      if (mpv is bool) mpvControls.value = mpv;
      final hideRe = box.get(_keyHideReReleases);
      if (hideRe is bool) hideReReleases.value = hideRe;
      final line = box.get(_keyProgressLine);
      if (line is bool) progressLine.value = line;
      final popups = box.get(_keyChatPopups);
      chatPopups.value = ChatPopups.values.where((m) => m.name == popups).firstOrNull ?? ChatPopups.paused;
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

  void setIdleSitsOut(bool on) {
    idleSitsOut.value = on;
    _put(_keyIdleSitsOut, on);
  }

  void setMpvControls(bool on) {
    mpvControls.value = on;
    _put(_keyMpvControls, on);
  }

  void setProgressLine(bool on) {
    progressLine.value = on;
    _put(_keyProgressLine, on);
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
