import 'package:flutter/foundation.dart';
import 'package:signals/signals_flutter.dart';

import '../../jellyfin/track_prefs.dart' show MpvTrack;
import '../../playback/media_marks.dart';
import '../../playback/playback_controller.dart';
import '../../queue/queue_controller.dart';
import '../../session/session_coordinator.dart';
import '../../shaders/shader_presets.dart';
import '../../state/settings.dart';
import '../player_settings.dart' show applyShaderChoice;
import '../volume.dart' as vol;
import 'controls_layout.dart';

/// A track pick from a track menu: audio id, subtitle id, or off.
typedef TrackPick = ({int? aid, int? sid, bool subtitlesOff});

/// The player controls, independent of how they look: what the controls
/// show (state, as signals) and what they do (actions), wired to the
/// session once. Both skins only draw this and call its actions, so a
/// control added here shows in both. Built by the session player per
/// mount; [fullscreen], [chatOpen] and [unread] are the shell's, passed in.
class PlayerControlsModel {
  final SessionCoordinator coord;
  final ReadonlySignal<bool> fullscreen;
  final ReadonlySignal<bool> chatOpen;
  final ReadonlySignal<int> unread;
  final VoidCallback _toggleFullscreen;
  final VoidCallback _toggleChat;
  final VoidCallback _changeVideo;
  final VoidCallback _collapse;
  final VoidCallback _leave;

  PlayerControlsModel({
    required this.coord,
    required this.fullscreen,
    required this.chatOpen,
    required this.unread,
    required VoidCallback onToggleFullscreen,
    required VoidCallback onToggleChat,
    required VoidCallback onChangeVideo,
    required VoidCallback onCollapse,
    required VoidCallback onLeave,
  }) : _toggleFullscreen = onToggleFullscreen,
       _toggleChat = onToggleChat,
       _changeVideo = onChangeVideo,
       _collapse = onCollapse,
       _leave = onLeave;

  PlaybackController get playback => coord.playback;
  QueueController get queue => coord.queue;
  AppSettings get settings => AppSettings.instance;

  // ---------------------------------------------------------------- state

  ReadonlySignal<Duration> get position => playback.position;
  ReadonlySignal<Duration> get duration => playback.duration;

  /// End of the cached range ahead of the position.
  ReadonlySignal<Duration> get buffered => playback.buffered;
  ReadonlySignal<List<MediaChapter>> get chapters => playback.chapters;
  ReadonlySignal<int?> get currentChapter => playback.currentChapter;
  ReadonlySignal<List<MpvTrack>> get tracks => playback.tracks;

  /// 0..`maxVolume`.
  ReadonlySignal<double> get volume => playback.volume;
  ReadonlySignal<SkipOffer?> get skipOffer => coord.skipOffer;
  ReadonlySignal<RenderMode> get renderMode => playback.renderMode;

  /// Play / pause as the session sees it ([PlayState]).
  late final Computed<PlayState> play = computed(() {
    final r = coord.serverState.value;
    final self = coord.selfMember.value;
    return switch (r?.transport) {
      'playing' => PlayState.playing,
      'finished' => PlayState.finished,
      _ => (self?.ready ?? false) && (self?.inSet ?? false) ? PlayState.waiting : PlayState.paused,
    };
  });

  /// Everything the layout depends on (not the position: that changes
  /// four times a second and only the timeline needs it).
  late final Computed<ControlsSnapshot> snapshot = computed(() {
    final queued = queue.items.value.firstOrNull;
    final continues = queue.continues.value;
    final next = coord.nextEpisode.value;
    return ControlsSnapshot(
      play: play.value,
      previousLabel: coord.previousEpisode.value?.label,
      // Up next's first item, else the next episode, else what continues
      // this (a file's next episode).
      nextLabel: queued?.title ?? next?.label ?? continues?.title,
      nextIsUpNext: queued != null,
      hasChapters: chapters.value.isNotEmpty,
      hasDuration: duration.value > Duration.zero,
      alone: coord.alone.value,
      // Not a signal: read again whenever the state changes.
      hasLink: coord.serverState.value != null && coord.currentLink() != null,
      fullscreen: fullscreen.value,
      chatOpen: chatOpen.value,
    );
  });

  /// The bar's clusters, in the layout's order.
  late final Computed<({List<BarControl> left, List<BarControl> right})> bar = computed(
    () => barControls(snapshot.value, settings.hiddenControls.value),
  );

  /// What the ⚙ menu lists now.
  List<ControlAction> menu() => menuActions(snapshot.peek(), settings.hiddenControls.peek());

  /// Ticks on each wheel / key volume step: the skins flash the volume.
  final volumeFlash = ValueNotifier(0);

  /// A menu of the controls is open (the player's Esc closes it).
  int menusOpen = 0;

  void dispose() => volumeFlash.dispose();

  // -------------------------------------------------------------- actions

  /// Space: ready / not ready (being ready is "play" in a server).
  void togglePlay() => coord.toggleReady();

  /// A seek bar's press or drag; through `player.seek`, the user-seek
  /// path, so everyone follows.
  void seek(Duration to) => playback.userSeek(to);

  /// Arrow keys: ±[secs], relative to a seek still in flight.
  void nudge(double secs) => coord.nudge(secs);

  /// +1:30 for everyone.
  void skipForward() => coord.skipForward();

  /// A skip pill (Skip OP / ED / 1:30).
  void skip(SkipOffer offer) => coord.skip(offer);

  /// PgDn (+1) / PgUp (-1). False when there is no chapter to go to.
  bool stepChapter(int delta) => coord.stepChapter(delta);

  void pickChapter(MediaChapter c) => coord.seekTo(c.start.inMicroseconds / 1e6);

  /// What plays next (Up next's first item, else the continuation), else
  /// the next episode. False when neither.
  bool next() {
    if (queue.head.peek() != null) {
      queue.skip();
      return true;
    }
    if (coord.nextEpisode.peek() == null) return false;
    coord.playNextEpisode();
    return true;
  }

  /// The previous episode. False without one.
  bool previous() {
    if (coord.previousEpisode.peek() == null) return false;
    coord.playPreviousEpisode();
    return true;
  }

  void playNextEpisode() => coord.playNextEpisode();

  void setVolume(double v) => playback.setVolume(v.clamp(0.0, vol.maxVolume));

  /// One volume step up (+1) or down (-1) from the wheel or ↑ / ↓;
  /// flashes the volume readout.
  void stepVolume(int step) {
    setVolume(vol.stepVolume(volume.peek(), step * vol.volumeStep));
    volumeFlash.value++;
  }

  double _beforeMute = 100;

  /// The speaker: mute, or back to the volume before.
  void toggleMute() {
    final v = volume.peek();
    if (v > 0) {
      _beforeMute = v;
      setVolume(0);
    } else {
      setVolume(_beforeMute <= 0 ? 100 : _beforeMute);
    }
  }

  void pickTrack(TrackPick p) => coord.selectTrack(aid: p.aid, sid: p.sid, subtitlesOff: p.subtitlesOff);

  /// Saved as the choice and applied live; a null quality keeps the
  /// saved one.
  void pickShader(ShaderPreset preset, ShaderQuality? quality) => applyShaderChoice(coord, preset, quality);

  void toggleTimeDisplay() => settings.setTimeDisplay(settings.timeDisplay.peek().toggled);

  void toggleFullscreen() => _toggleFullscreen();

  void toggleChat() {
    coord.markInput();
    _toggleChat();
  }

  void changeVideo() => _changeVideo();

  /// Back to the library (keeps playing in the mini player).
  void collapse() => _collapse();

  /// Asks before leaving the server.
  void leave() => _leave();

  void reload() {
    coord.markInput();
    coord.reloadVideo();
  }

  void markAllReady() => coord.forcePlayAll();

  String? link() => coord.currentLink();
}
