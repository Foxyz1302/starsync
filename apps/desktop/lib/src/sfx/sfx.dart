enum SfxKind {
  ready,
  unready,
  forceReady,
  forceUnready,
  forcePlay,
  forceHold,
  kick,
  join,
  leave,
  stale,
  swap,
  seek,
  pause,
  resume,
  chat,
  warn,
}

class SfxCue {
  final SfxKind kind;
  final int readyIndex;
  const SfxCue(this.kind, {this.readyIndex = 0});
}

SfxKind? sfxForFeedAction(String action) {
  switch (action) {
    case 'ready':
      return SfxKind.ready;
    case 'unready':
      return SfxKind.unready;
    case 'force-ready':
      return SfxKind.forceReady;
    case 'force-unready':
      return SfxKind.forceUnready;
    case 'force-play':
      return SfxKind.forcePlay;
    case 'force-hold':
      return SfxKind.forceHold;
    case 'kick':
      return SfxKind.kick;
    case 'join':
      return SfxKind.join;
    case 'leave':
      return SfxKind.leave;
    case 'stale':
      return SfxKind.stale;
    case 'swap':
      return SfxKind.swap;
    case 'seek':
      return SfxKind.seek;
    case 'pause':
      return SfxKind.pause;
    case 'resume':
      return SfxKind.resume;
    case 'chat':
      return SfxKind.chat;
    default:
      return null;
  }
}

abstract class SfxService {
  Future<void> play(SfxCue cue);
}

class NoopSfxService implements SfxService {
  const NoopSfxService();

  @override
  Future<void> play(SfxCue cue) async {}
}
