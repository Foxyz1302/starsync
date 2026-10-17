import 'dart:async';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart' show SharedSource;

final _log = createLogger('session');

/// A link this member passes on, read from the site once ([SharedSource]):
/// its page URL, the reader, and the page's subtitles for the player.
class SharedLink {
  final String url;
  final SharedSource source;
  final List<YtDlpSubtitle> subtitles;
  SharedLink(this.url, this.source, {this.subtitles = const []});
}

/// The links this member passes on and reads once, by page URL: the one a
/// swap check read (until the swap's state takes it), Up next's warm one
/// (until the swap that puts it up takes it), and the current media's.
/// Each one's player opens [SharedSource.playerUrl] and its relay serves
/// [SharedSource.upload]. A page with a pieces track (HLS/DASH) is not
/// shared ([fits]): its player and relay keep their own fetches.
class SharedLinks {
  SharedLink? _current;
  ({String queueId, SharedLink link})? _warm;
  SharedLink? _pending;
  Timer? _pendingTimer;

  /// A link that can be shared: a media file, or a page whose relay tracks
  /// are all plain files (one, or a video and an audio).
  static bool fits(LinkProbe probe) =>
      probe.relayProblem == null && (!probe.isPage || (probe.info?.tracks.every((t) => !t.format.isPieces) ?? false));

  static List<YtDlpSubtitle> _subs(LinkProbe? probe) => probe?.info?.play?.subtitles ?? const [];

  /// The swap check of a link this member passes on: a shared source
  /// for [url] over [media], started (the tracks' sizes read). Kept for
  /// the swap's state ([current]) for a minute, then dropped.
  Future<SharedSource> forSwap(String url, RelayMedia media, LinkProbe probe,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final s = SharedSource(media);
    try {
      await s.start().timeout(timeout);
    } catch (_) {
      unawaited(s.close());
      rethrow;
    }
    _dropPending();
    _pending = SharedLink(url, s, subtitles: _subs(probe));
    _pendingTimer = Timer(const Duration(seconds: 60), _dropPending);
    return s;
  }

  void _dropPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    final p = _pending;
    _pending = null;
    if (p != null && !identical(p, _current)) unawaited(p.source.close());
  }

  /// The current media's shared source for [url]: the one it has, else
  /// Up next's warm one for [queueId], else the swap check's, else a new
  /// one over [media] (opened, its sizes read meanwhile). Null when the
  /// link cannot be shared ([fits], or it does not open): the caller
  /// keeps today's two fetches. Any other current one is closed.
  Future<SharedSource?> current(String url, LinkProbe probe, RelayMedia Function() media,
      {String queueId = ''}) async {
    final had = _current;
    if (had != null && had.url == url) return had.source;
    await closeCurrent();
    SharedLink? link;
    final pending = _pending, warm = _warm;
    if (warm != null && warm.link.url == url && queueId.isNotEmpty && warm.queueId == queueId) {
      // The swap carries the warm relay's source on: the player reads the
      // reader that source serves.
      _warm = null;
      link = warm.link;
      if (pending != null && pending.url == url) _dropPending();
    } else if (pending != null && pending.url == url) {
      _pendingTimer?.cancel();
      _pending = null;
      link = pending;
    } else if (fits(probe)) {
      final s = SharedSource(media());
      try {
        await s.open();
      } catch (e) {
        _log.info('link ${logUrl(url)} not read once here: $e');
        unawaited(s.close());
        return null;
      }
      link = SharedLink(url, s, subtitles: _subs(probe));
    }
    _current = link;
    return link?.source;
  }

  /// The current media's shared source when it reads [url].
  SharedSource? currentFor(String url) => _current?.url == url ? _current!.source : null;

  /// Up next item [queueId]'s shared source for [url] (fed to its warm
  /// relay), made over [media] and opened; the one it has is kept. Null
  /// when the link cannot be shared.
  Future<SharedSource?> warm(String queueId, String url, LinkProbe probe, RelayMedia Function() media) async {
    final had = _warm;
    if (had != null && had.queueId == queueId && had.link.url == url) return had.link.source;
    dropWarm();
    if (!fits(probe)) return null;
    final s = SharedSource(media());
    final link = SharedLink(url, s, subtitles: _subs(probe));
    _warm = (queueId: queueId, link: link);
    try {
      await s.open();
    } catch (e) {
      _log.info('Up next ${logUrl(url)} not read once here: $e');
      if (identical(_warm?.link, link)) _warm = null;
      unawaited(s.close());
      return null;
    }
    return identical(_warm?.link, link) ? s : null;
  }

  /// The warm one goes (its relay ended, the item is no longer first);
  /// with [queueId], only that item's.
  void dropWarm([String? queueId]) {
    final w = _warm;
    if (w == null || (queueId != null && w.queueId != queueId)) return;
    _warm = null;
    unawaited(w.link.source.close());
  }

  /// What a player opens for [url] when it is shared here (the current
  /// media's or the warm one), opened: null otherwise.
  Future<SharedLink?> playerFor(String url) async {
    final link = _current?.url == url ? _current : (_warm?.link.url == url ? _warm!.link : null);
    if (link == null) return null;
    try {
      await link.source.open();
      return link;
    } catch (_) {
      return null;
    }
  }

  /// [url] is shared here (the current media's or the warm one).
  bool has(String url) => _current?.url == url || _warm?.link.url == url;

  Future<void> closeCurrent() async {
    final c = _current;
    _current = null;
    if (c != null) await c.source.close();
  }

  /// Leave, a new session: everything goes.
  Future<void> closeAll() async {
    _dropPending();
    dropWarm();
    await closeCurrent();
  }
}
