import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart';

import 'app_events.dart';
import 'media_plan.dart' show ServerAddress;
import 'party.dart' show isPresent;

/// This member as a relay source: the current media's bytes (its file, a
/// link it passes on, its Jellyfin stream) on `/r/.../source`, and Up next's
/// first item on the warm relay (`?q=<queueId>`), which the swap that puts
/// the item up carries on as the media's. A source re-dials by itself
/// through a drop of this app (the server keeps the relay through the
/// grace; the same `info` continues it).
class RelayFeeder {
  final ServerAddress Function() server;
  final void Function(AppEvent event) notify;
  RelayFeeder({required this.server, required this.notify});

  RelaySource? _source;
  int _mediaId = -1;
  ({String queueId, RelaySource src})? _warm;

  /// This member serves the current media's bytes through the server.
  final relaying = signal(false);

  /// The media id this member serves (-1: none).
  int get mediaId => _mediaId;

  /// The tracks of Up next item [queueId] when this member feeds its warm
  /// relay and has opened them (empty otherwise).
  List<RelayTrack> warmTracks(String queueId) => _warm?.queueId == queueId ? _warm!.src.tracks : const [];

  /// Serves [media] for media [mediaId] on this member's relay channel.
  /// The server only pulls while someone watches through it. When the
  /// media came from Up next item [queueId] whose warm relay this member
  /// feeds, that source carries on instead. [name] and [duration] go in
  /// the `info`, the same on every dial, so the server knows a re-dial
  /// after a drop as the same media.
  void serve(int mediaId, RelayMedia media,
      {bool announce = false, String queueId = '', String name = '', double duration = 0}) {
    // Already serving this media (it re-dials by itself through a drop).
    if (_source != null && _mediaId == mediaId) {
      unawaited(media.close());
      return;
    }
    stop();
    final warm = _warm;
    if (queueId.isNotEmpty && warm != null && warm.queueId == queueId) {
      _warm = null;
      unawaited(media.close());
      _adopt(mediaId, warm.src, announce: announce, started: true);
      return;
    }
    final src = RelaySource(server().sourceChannel(), media, name: name, duration: duration);
    _adopt(mediaId, src, announce: announce, started: false);
  }

  void _adopt(int mediaId, RelaySource src, {required bool announce, required bool started}) {
    _source = src;
    _mediaId = mediaId;
    relaying.value = true;
    if (announce) notify(const RelayStarted());
    unawaited(() async {
      if (!started) {
        try {
          await src.start();
        } catch (e) {
          debugPrint('relay source failed: $e');
          if (identical(_source, src)) {
            _clear();
            notify(RelayFailed('$e'));
          }
          return;
        }
      }
      await src.done;
      if (identical(_source, src)) _clear();
    }());
  }

  void _clear() {
    _source = null;
    _mediaId = -1;
    relaying.value = false;
  }

  /// Stops serving the current media.
  void stop() {
    final src = _source;
    _clear();
    if (src != null) unawaited(src.close());
  }

  /// Feeds the warm relay of Up next item [queueId] from here with [media];
  /// one already feeding it is kept. The server pulls only while someone
  /// preloads it, and closes the channel once the item is no longer first
  /// (the source then stops).
  void feedWarm(String queueId, RelayMedia media) {
    if (_warm?.queueId == queueId) {
      unawaited(media.close());
      return;
    }
    stopWarm();
    final src = RelaySource(server().sourceChannel(queueId), media);
    _warm = (queueId: queueId, src: src);
    unawaited(() async {
      try {
        await src.start();
      } catch (e) {
        debugPrint('warm relay source of $queueId failed: $e');
        if (identical(_warm?.src, src)) _warm = null;
        return;
      }
      await src.done;
      if (identical(_warm?.src, src)) _warm = null;
    }());
  }

  void stopWarm() {
    final w = _warm;
    _warm = null;
    if (w != null) unawaited(w.src.close());
  }

  /// Leave, or a media this member no longer serves.
  void stopAll() {
    stop();
    stopWarm();
  }
}

/// Someone present needs this member's relay of Jellyfin [ref]: the
/// server's own login does not pass it on (`state.relay`) and a present
/// member other than [selfId] does not play that server with its own
/// account. A member whose account list is not reported yet (`caps` say it
/// has Jellyfin, `jf` still empty) is asked again with the next state.
/// Without anyone needing it, no relay channel is opened.
bool jellyfinRelayNeeded(StateBroadcast r, JellyfinRef ref, String selfId) {
  if (r.relay) return false;
  for (final m in r.members) {
    if (m.id == selfId || !isPresent(m)) continue;
    if (m.jf[ref.serverId] == true) continue;
    if (m.caps.jellyfin && m.jf.isEmpty) continue;
    return true;
  }
  return false;
}
