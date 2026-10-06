import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';

// App preferences (Settings page), one Hive box. Signals start at their
// defaults and take the stored values once [AppSettings.ensureLoaded]
// finishes; setters write through.

const settingsBoxName = 'settings';

const _keyHwdecMode = 'hwdecMode';
const _keyHwdecCustom = 'hwdecCustom';
const _keyAutoCheckUpdates = 'autoCheckUpdates';

enum HwdecMode { auto, off, custom }

class AppSettings {
  static final AppSettings instance = AppSettings();

  final hwdecMode = signal(HwdecMode.auto);
  final hwdecCustom = signal('');
  final autoCheckUpdates = signal(true);

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
