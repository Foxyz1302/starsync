/// The app's sounds. Only events that carry news get one: no sound for
/// what the video itself makes obvious (start, pause, end, seeks).
enum SfxKind {
  /// Someone readies up; pitch climbs with [SfxCue.readyIndex].
  ready,
  unready,
  /// Someone marks everyone ready.
  forceReady,
  join,
  leave,
  /// Someone sat you out (played by the session, not from a feed action).
  kick,
  /// A new video or episode is put up.
  swap,
  chat,
  /// Auto sit-out set you away (idle, minimised).
  warn,
  /// The connection to the server dropped / came back.
  lost,
  back,
  /// Someone pokes you for attention; plays only on your end.
  nudge,
}

class SfxCue {
  final SfxKind kind;
  final int readyIndex;
  const SfxCue(this.kind, {this.readyIndex = 0});
}

SfxKind? sfxForFeedAction(String action) => switch (action) {
      'ready' => SfxKind.ready,
      'unready' => SfxKind.unready,
      'force-ready' => SfxKind.forceReady,
      'join' => SfxKind.join,
      'leave' => SfxKind.leave,
      'swap' => SfxKind.swap,
      'chat' => SfxKind.chat,
      _ => null,
    };

abstract class SfxService {
  Future<void> play(SfxCue cue);
}

class NoopSfxService implements SfxService {
  const NoopSfxService();

  @override
  Future<void> play(SfxCue cue) async {}
}
