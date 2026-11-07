import 'dart:async' show Timer;
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show UpdateChannel, appVersion, defaultUpdateChannel;

import '../controls/model/controls_prefs.dart';
import '../danmaku/danmaku.dart' show DanmakuStyle;
import '../shaders/shader_presets.dart';
import '../session/notice_prefs.dart';
import 'settings_schema.dart';

export '../session/notice_prefs.dart' show ChatPopups, NotifyPrefs;

// App preferences (Settings page), one Hive box. Signals start at their
// defaults and take the stored values once [AppSettings.ensureLoaded]
// finishes; setters write through.

const settingsBoxName = 'settings';

const _keyHwdecMode = 'hwdecMode';
const _keyHwdecCustom = 'hwdecCustom';
const _keyShaderPreset = 'shaderPreset';
const _keyShaderQuality = 'shaderQuality';
const _keyCustomShaders = 'customShaders';
const _keyAvatarShape = 'avatarShape';
const _keyWaitDisplay = 'waitDisplay';
const _keyBadgeStyle = 'badgeStyle';
const _keyAvatarRow = 'avatarRow';
const _keyBrbHold = 'brbHoldMs';
const _keyContinueHold = 'continueHoldMs';
const _keyAutoAdvance = 'autoAdvance';
/// Legacy: true was the uosc design (now [ControlsSkin.minimal]); read
/// once when [_keyControlsSkin] is missing.
const _keyMpvControls = 'mpvControls';
const _keyControlsSkin = 'controlsSkin';
const _keyTimeDisplay = 'timeDisplay';
const _keyControlsSize = 'controlsSize';
const _keyHiddenControls = 'hiddenControls';
const _keyHideReReleases = 'hideReReleases';
const _keyProgressLine = 'progressLine';
const _keySoundVolume = 'soundVolume';
const _keySoundsOff = 'soundsOff';
const _keySoundPreset = 'soundPreset';
const _keyWelcomeDismissed = 'welcomeDismissed';
const _keySoundPresetFor = 'soundPresetFor';
const _keyChatPopups = 'chatPopups';
const _keyNotifyPeople = 'notifyPeople';
const _keyShareDiagnostics = 'shareDiagnostics';
const _keyWhatsNewSeen = 'whatsNewSeen';
const _keyWhatsNewNotes = 'whatsNewNotes';
const _keyScreenResVideo = 'screenResVideo';
const _keyLiftSubtitles = 'liftSubtitles';
const _keyNotifyStyle = 'notifyStyle';
const _keySubScale = 'subScale';
const _keyDanmakuStyle = 'danmakuStyle';
const _keyUpdateChannel = 'updateChannel';
const _keyConfigAddress = 'configAddress';
const _keyPlayerVolume = 'playerVolume';
const _keyAnimeFlowAddress = 'animeFlowAddress';

/// A file next to the binary naming a channel (`dev` / `stable`): the
/// app takes it as the update channel on its next start and deletes it.
/// The one-time command `tool/dev_release.sh` prints writes it.
const updateChannelFileName = 'update-channel';

enum HwdecMode { auto, off, custom }

/// How notifications show over the full player ([AppSettings.notifyStyle]).
enum NotifyStyle {
  toasts('Toasts'),
  danmaku('Danmaku');

  final String label;
  const NotifyStyle(this.label);
}

/// How the group waiting for someone's BRB (or yours) shows over the
/// paused picture ([AppSettings.waitDisplay]).
enum WaitDisplay {
  /// The status pill at the bottom says it (the default).
  pill('Pill'),

  /// A card in the middle of the picture (`WaitCard`).
  card('Centre card'),

  /// The card, fading with the controls (a Space hold always shows it).
  fadingCard('Card that fades with the controls');

  final String label;
  const WaitDisplay(this.label);
}

/// How an avatar's standing badge shows ([AppSettings.badgeStyle]).
enum BadgeStyle {
  /// A cup, "Zz", a crossed eye (the default).
  icons('Icons'),

  /// "BRB", "AFK", "Out".
  words('Words');

  final String label;
  const BadgeStyle(this.label);
}

/// The Space hold to BRB ([AppSettings.brbHoldMs]): its range and default, ms.
const brbHoldRange = (min: 400, max: 800, initial: 600);

/// The Space hold to continue without whoever is BRB
/// ([AppSettings.continueHoldMs]): its range and default, ms.
const continueHoldRange = (min: 1500, max: 3000, initial: 2000);

/// The mpv `hwdec` of [HwdecMode.auto]. Windows: 'auto-copy' (decoded on
/// the GPU, frames copied back): media_kit renders through ANGLE, where
/// plain 'auto' picks the dxva2 interop, which cannot create its EGL
/// surface there ("Failed to create EGL surface"). Elsewhere 'auto'.
String get autoHwdec => Platform.isWindows ? 'auto-copy' : 'auto';

class AppSettings {
  static final AppSettings instance = AppSettings();

  /// The running build's version: picks the default [updateChannel].
  final String runningVersion;
  /// The [updateChannelFileName] file to adopt at load (null: none).
  final File? channelFile;

  AppSettings({this.runningVersion = appVersion, File? channelFile})
      : channelFile = channelFile ?? _channelFileNextToBinary();

  static File? _channelFileNextToBinary() {
    try {
      return File('${File(Platform.resolvedExecutable).parent.path}/$updateChannelFileName');
    } catch (_) {
      return null;
    }
  }

  final hwdecMode = signal(HwdecMode.auto);
  final hwdecCustom = signal('');
  /// Where updates come from (Settings → Updates). Never chosen: dev for
  /// a test build, else stable; a test build stores dev on its first
  /// start, so the install stays on test builds after a release (also
  /// when that release updated it).
  late final updateChannel = signal(defaultUpdateChannel(runningVersion));
  /// An extra address for the signed config, tried before the others
  /// (Settings → Updates → More, "Config address": a mirror). Empty: none.
  /// What it serves still needs the developer's signature.
  final configAddress = signal('');
  /// The AnimeFlow address the last server that offered one gave
  /// (`welcome.animeFlow`): the Schedule's statuses and requests use it,
  /// also outside a server, and your server offers it on. Not a setting
  /// (nothing shows it to change); empty: none yet.
  final animeFlowAddress = signal('');
  /// An episode this app puts up (Jellyfin, a file of a local show) is
  /// continued by the next one (Up next's `auto` item, the server's
  /// countdown at its end).
  final autoAdvance = signal(true);
  /// People's pictures as circles instead of rounded squares (Settings →
  /// Party → More: "Avatar shape").
  final avatarCircle = signal(false);
  /// How the group waiting for someone's BRB shows (Settings → Party →
  /// More: "Waiting display").
  final waitDisplay = signal(WaitDisplay.pill);
  /// Standing badges as icons or words (Settings → Party → More: "Badges").
  final badgeStyle = signal(BadgeStyle.icons);
  /// A row of avatars (the top bar, the fullscreen row) overlapping or
  /// side by side (Settings → Party → More: "Avatars in the top bar").
  /// Null until picked: the row follows the shape (circles overlap,
  /// rounded squares sit side by side); see [overlapAvatars].
  final avatarOverlap = signal<bool?>(null);
  /// Whether a row of avatars overlaps: [avatarOverlap], else the shape's.
  late final overlapAvatars = computed(() => avatarOverlap.value ?? avatarCircle.value);
  /// Held this long, Space is BRB (Settings → Player → More: "BRB
  /// hold"; [brbHoldRange]).
  final brbHoldMs = signal(brbHoldRange.initial);
  /// Held this long while someone else is BRB, Space continues without
  /// them (Settings → Player → More: "Continue-without hold";
  /// [continueHoldRange]).
  final continueHoldMs = signal(continueHoldRange.initial);
  /// The player controls' skin (`controls/`). Applies live.
  final controlsSkin = signal(ControlsSkin.standard);
  /// The bar's clock: elapsed / total or the time left (a click on the
  /// clock switches it).
  final timeDisplay = signal(TimeDisplay.elapsed);
  final controlsSize = signal(ControlsSize.normal);
  /// Optional bar buttons switched off (they stay in the top bar's ⋯).
  final hiddenControls = signal<Set<OptionalControl>>(const {});
  /// Library: leave out of "Latest in X" what was added long after it
  /// first aired (re-uploads, old seasons added late); set in the Latest
  /// row's ⋮ menu.
  final hideReReleases = signal(true);
  /// A 2 px progress line at the bottom of the video while the controls
  /// are hidden (both skins). Applies live.
  final progressLine = signal(true);
  /// Send this app's log lines to the server's session log while in a
  /// session (never chat). Off: no lines are sent, only a note that it is
  /// off and the problems the user marks.
  final shareDiagnostics = signal(true);
  /// The video output renders at the player's size on screen, so mpv
  /// scales the picture (and runs shaders) and draws subtitles at screen
  /// resolution; off: at the video's own size, scaled by Flutter. Applies
  /// live (GPU rendering only).
  final screenResVideo = signal(true);
  /// Bottom subtitles also move up above the control bar while it is up
  /// (mpv `sub-pos`; the quick chat box always lifts them). Default off.
  /// Applies live.
  final liftSubtitles = signal(false);
  /// Subtitle size, mpv `sub-scale` (1: as the file has them), 0.5..2.
  /// Applies live and to each new player.
  final subScale = signal(1.0);
  /// How notifications show over the full player: toasts (the default),
  /// or chat and short notices flying across the picture as danmaku
  /// (`danmaku/danmaku_notices.dart`; problems stay toasts). Applies live.
  final notifyStyle = signal(NotifyStyle.toasts);
  /// How those lines look and move (stored as one map, [DanmakuStyle.toJson]).
  final danmakuStyle = signal(const DanmakuStyle());
  /// Chat message toasts (default: all). Applies live.
  final chatPopups = signal(ChatPopups.all);
  /// Joins and leaves also notify while sitting out or with the window in
  /// the background (default off). Applies live.
  final notifyPeople = signal(false);

  /// The notification choices as the Notifier reads them.
  NotifyPrefs get notifyPrefs => NotifyPrefs(chat: chatPopups.peek(), people: notifyPeople.peek());
  /// App sounds (`sfx/`): 0..1, 0 = silent.
  final soundVolume = signal(1.0);
  /// The video's volume as last set (0..150, mpv's `volume-max`): every
  /// start begins there. Written a moment after the last change (a wheel
  /// makes many steps).
  final playerVolume = signal(100.0);
  /// `SfxKind` names switched off one by one.
  final soundsOff = signal<Set<String>>(const {});
  /// The sound set (`SoundPreset` name) every sound uses unless
  /// [soundPresetFor] picks another one for it.
  final soundPreset = signal('cosmic');
  /// The offline welcome band's × was pressed: never show it again.
  final welcomeDismissed = signal(false);
  /// `SfxKind` name -> `SoundPreset` name, per-sound overrides.
  final soundPresetFor = signal<Map<String, String>>(const {});

  /// What's new (`update/whats_new.dart`): the version whose card was
  /// shown, and the notes last kept (a version's `ReleaseNotes` as JSON).
  String? whatsNewSeen;
  Map<String, Object?>? whatsNewNotes;
  /// The box was empty when this run opened it: a new install.
  bool freshInstall = false;

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
      freshInstall = box.isEmpty;
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
      await _loadUpdateChannel(box);
      final configAt = box.get(_keyConfigAddress);
      if (configAt is String) configAddress.value = configAt;
      final flowAt = box.get(_keyAnimeFlowAddress);
      if (flowAt is String) animeFlowAddress.value = flowAt;
      final advance = box.get(_keyAutoAdvance);
      if (advance is bool) autoAdvance.value = advance;
      avatarCircle.value = box.get(_keyAvatarShape) == 'circle';
      final wait = box.get(_keyWaitDisplay);
      waitDisplay.value = WaitDisplay.values.where((w) => w.name == wait).firstOrNull ?? WaitDisplay.pill;
      final badges = box.get(_keyBadgeStyle);
      badgeStyle.value = BadgeStyle.values.where((b) => b.name == badges).firstOrNull ?? BadgeStyle.icons;
      avatarOverlap.value = switch (box.get(_keyAvatarRow)) {
        'overlap' => true,
        'side' => false,
        _ => null,
      };
      final brbMs = box.get(_keyBrbHold);
      if (brbMs is int) brbHoldMs.value = brbMs.clamp(brbHoldRange.min, brbHoldRange.max);
      final continueMs = box.get(_keyContinueHold);
      if (continueMs is int) continueHoldMs.value = continueMs.clamp(continueHoldRange.min, continueHoldRange.max);
      controlsSkin.value =
          ControlsSkin.fromStored(box.get(_keyControlsSkin), legacyMpvControls: box.get(_keyMpvControls));
      final time = box.get(_keyTimeDisplay);
      timeDisplay.value = TimeDisplay.values.where((t) => t.name == time).firstOrNull ?? TimeDisplay.elapsed;
      final size = box.get(_keyControlsSize);
      controlsSize.value = ControlsSize.values.where((t) => t.name == size).firstOrNull ?? ControlsSize.normal;
      final hidden = box.get(_keyHiddenControls);
      if (hidden is List) {
        hiddenControls.value = Set.unmodifiable(OptionalControl.values.where((c) => hidden.contains(c.name)));
      }
      final hideRe = box.get(_keyHideReReleases);
      if (hideRe is bool) hideReReleases.value = hideRe;
      final line = box.get(_keyProgressLine);
      if (line is bool) progressLine.value = line;
      final screenRes = box.get(_keyScreenResVideo);
      if (screenRes is bool) screenResVideo.value = screenRes;
      final lift = box.get(_keyLiftSubtitles);
      if (lift is bool) liftSubtitles.value = lift;
      final scale = box.get(_keySubScale);
      if (scale is num && scale.isFinite) subScale.value = scale.toDouble().clamp(0.5, 2.0);
      final notifyAs = box.get(_keyNotifyStyle);
      notifyStyle.value = NotifyStyle.values.where((m) => m.name == notifyAs).firstOrNull ?? NotifyStyle.toasts;
      final style = box.get(_keyDanmakuStyle);
      if (style is Map) danmakuStyle.value = DanmakuStyle.fromJson(style);
      final share = box.get(_keyShareDiagnostics);
      if (share is bool) shareDiagnostics.value = share;
      final popups = box.get(_keyChatPopups);
      chatPopups.value = ChatPopups.values.where((m) => m.name == popups).firstOrNull ?? ChatPopups.all;
      final people = box.get(_keyNotifyPeople);
      if (people is bool) notifyPeople.value = people;
      final vol = box.get(_keySoundVolume);
      if (vol is num) soundVolume.value = vol.toDouble().clamp(0, 1);
      final video = box.get(_keyPlayerVolume);
      if (video is num && video.isFinite) playerVolume.value = video.toDouble().clamp(0, 150);
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
      final seen = box.get(_keyWhatsNewSeen);
      if (seen is String) whatsNewSeen = seen;
      final notes = box.get(_keyWhatsNewNotes);
      if (notes is Map) whatsNewNotes = {for (final e in notes.entries) '${e.key}': e.value};
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

  Future<void> _loadUpdateChannel(Box box) async {
    UpdateChannel? requested;
    final file = channelFile;
    try {
      if (file != null && file.existsSync()) {
        requested = UpdateChannel.fromName(file.readAsStringSync().trim());
        file.deleteSync();
      }
    } catch (e) {
      debugPrint('update channel file: $e');
    }
    final stored = requested ?? UpdateChannel.fromName(box.get(_keyUpdateChannel));
    final channel = stored ?? defaultUpdateChannel(runningVersion);
    updateChannel.value = channel;
    if (channel.name != box.get(_keyUpdateChannel) && (requested != null || channel == UpdateChannel.dev)) {
      await box.put(_keyUpdateChannel, channel.name);
    }
  }

  void setUpdateChannel(UpdateChannel channel) {
    updateChannel.value = channel;
    _put(_keyUpdateChannel, channel.name);
  }

  void setConfigAddress(String url) {
    configAddress.value = url.trim();
    _put(_keyConfigAddress, url.trim());
  }

  /// Keeps [url] as [animeFlowAddress] (a server offered it); empty or
  /// the same changes nothing.
  void rememberAnimeFlow(String url) {
    final v = url.trim();
    if (v.isEmpty || v == animeFlowAddress.peek()) return;
    animeFlowAddress.value = v;
    _put(_keyAnimeFlowAddress, v);
  }

  void setAutoAdvance(bool on) {
    autoAdvance.value = on;
    _put(_keyAutoAdvance, on);
  }

  void setAvatarCircle(bool on) {
    avatarCircle.value = on;
    _put(_keyAvatarShape, on ? 'circle' : 'rounded');
  }

  void setWaitDisplay(WaitDisplay d) {
    waitDisplay.value = d;
    _put(_keyWaitDisplay, d.name);
  }

  void setBadgeStyle(BadgeStyle b) {
    badgeStyle.value = b;
    _put(_keyBadgeStyle, b.name);
  }

  void setAvatarOverlap(bool on) {
    avatarOverlap.value = on;
    _put(_keyAvatarRow, on ? 'overlap' : 'side');
  }

  void setBrbHold(int ms) {
    brbHoldMs.value = ms.clamp(brbHoldRange.min, brbHoldRange.max);
    _put(_keyBrbHold, brbHoldMs.value);
  }

  void setContinueHold(int ms) {
    continueHoldMs.value = ms.clamp(continueHoldRange.min, continueHoldRange.max);
    _put(_keyContinueHold, continueHoldMs.value);
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

  void setScreenResVideo(bool on) {
    screenResVideo.value = on;
    _put(_keyScreenResVideo, on);
  }

  void setLiftSubtitles(bool on) {
    liftSubtitles.value = on;
    _put(_keyLiftSubtitles, on);
  }

  void setSubScale(double v) {
    subScale.value = v.clamp(0.5, 2.0);
    _put(_keySubScale, subScale.value);
  }

  void setNotifyStyle(NotifyStyle style) {
    notifyStyle.value = style;
    _put(_keyNotifyStyle, style.name);
  }

  void setDanmakuStyle(DanmakuStyle style) {
    if (style == danmakuStyle.peek()) return;
    danmakuStyle.value = style;
    _put(_keyDanmakuStyle, style.toJson());
  }

  void setShareDiagnostics(bool on) {
    shareDiagnostics.value = on;
    _put(_keyShareDiagnostics, on);
  }

  void setChatPopups(ChatPopups mode) {
    chatPopups.value = mode;
    _put(_keyChatPopups, mode.name);
  }

  void setNotifyPeople(bool on) {
    notifyPeople.value = on;
    _put(_keyNotifyPeople, on);
  }

  void setSoundVolume(double v) {
    soundVolume.value = v.clamp(0, 1);
    _put(_keySoundVolume, soundVolume.value);
  }

  Timer? _playerVolumeWrite;

  void setPlayerVolume(double v) {
    playerVolume.value = v.clamp(0, 150);
    _playerVolumeWrite?.cancel();
    _playerVolumeWrite = Timer(const Duration(milliseconds: 400), () => _put(_keyPlayerVolume, playerVolume.peek()));
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

  Future<void> setWhatsNewSeen(String version) {
    whatsNewSeen = version;
    return _put(_keyWhatsNewSeen, version);
  }

  Future<void> setWhatsNewNotes(Map<String, Object?> notes) {
    whatsNewNotes = notes;
    return _put(_keyWhatsNewNotes, notes);
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
