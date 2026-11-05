/// The app's sounds. Only events that carry news get one: no sound for
/// what the video itself makes obvious (start, pause, end, seeks).
enum SfxKind {
  /// Someone is back from BRB ([SfxCue.readyIndex] pitches it).
  ready,
  /// Someone is BRB.
  unready,
  /// Someone continued without the ones the group waited for.
  forceReady,
  join,
  leave,
  /// Someone set you out, BRB, or went on without you (played by the
  /// session, not from a feed action).
  kick,
  /// A new video or episode is put up.
  swap,
  chat,
  /// This app set you AFK or out (idle, minimised).
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
      'back' => SfxKind.ready,
      'brb' => SfxKind.unready,
      'continue' => SfxKind.forceReady,
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
