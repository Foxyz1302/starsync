import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../files/thumbnails.dart';
import '../jellyfin/accounts.dart';
import '../jellyfin/format.dart' show pickFor;
import '../jellyfin/session_media.dart';
import '../library/media_refs.dart';
import '../screens/home/picked_media.dart';
import '../session/app_events.dart' show AddedToUpNext;
import '../session/media_art.dart';
import '../session/session_coordinator.dart';
import '../sync/avatar_cache.dart';

// What's next on this app (see ARCHITECTURE.md "What's next" and "Up
// next"): the server's queue as signals (Up next and its continuation),
// adding to it (probed, with a picture), the continuation of what this
// app put up (the next Jellyfin episode, the next file of a local show),
// the server's countdown as the end card shows it, putting an item up
// when the server asks this app (`queuePlay`), and keeping the item that
// plays next ready (the media pipeline prepares it).

/// The end-of-media card for the first item (Up next's, else the
/// continuation). [secondsLeft]: the server's countdown (`state.advance`);
/// null when none runs (cancelled, or nothing counts down), then the card
/// offers Play now only. [waitingFor]: the countdown ran out and the one
/// who puts the item up is not here (its name).
class UpNextCountdown {
  final int mediaId;
  final QueueItem item;
  final int? secondsLeft;
  final String? waitingFor;
  const UpNextCountdown({required this.mediaId, required this.item, this.secondsLeft, this.waitingFor});
}

/// The first item's readiness on this app.
enum WarmState { idle, warming, ready, failed }

class QueueController {
  final SessionCoordinator coord;
  QueueController(this.coord);

  /// Queued items' pictures by hash, from `/i/`.
  late final PictureCache thumbs = PictureCache(coord.connection.client,
      route: 'i', keep: RelayConstants.maxQueueItems + 8, live: (s) => [for (final q in s.queue) q.thumb]);

  /// Up next, in order, without the continuation (empty when nothing is
  /// queued or not in a server).
  late final Computed<List<QueueItem>> items = computed(
      () => [for (final q in coord.serverState.value?.queue ?? const <QueueItem>[]) if (!q.auto) q]);

  /// The continuation of what plays (`auto`: the next episode), shared by
  /// everyone; null when none.
  late final Computed<QueueItem?> continues =
      computed(() => coord.serverState.value?.queue.where((q) => q.auto).firstOrNull);

  /// What plays next: Up next's first item, else the continuation.
  late final Computed<QueueItem?> head = computed(() => coord.serverState.value?.queue.firstOrNull);

  /// The end card while the media has ended with something next (see
  /// [UpNextCountdown]).
  final countdown = signal<UpNextCountdown?>(null);

  /// The first item's id and how ready it is here (null: nothing to get
  /// ready on this app).
  final warm = signal<({String id, WarmState state})?>(null);

  /// The next episodes of the Jellyfin series playing, on an app that
  /// plays it with its own account (the first one is what continues it;
  /// the rest show greyed under "Continues with", "+" adds one).
  final continuation = signal<List<EpisodeLink>>(const []);

  /// The mediaId whose continuation was cleared (by anyone: `cancel`).
  final _hiddenFor = signal(-1);

  /// The queue popover is open: the Up next button holds the controls up.
  final popoverOpen = signal(false);

  // What adder-only items stand for, by their key (a link passed on from
  // here, a file here). Never leaves this app.
  final Map<String, ({PickedMedia pick, DateTime at})> _local = {};
  final Map<String, DateTime> _performing = {};
  Timer? _timer;
  bool _attached = false;
  // The mediaId whose continuation this app added (or is adding).
  int _continuedFor = -1;
  // A restarted server waits for what played (that mediaId) to come back.
  int _restoreFrom = -1;
  String _continuationFor = '';
  final _random = Random.secure();

  String get _me => coord.connection.memberId;

  void attach() {
    if (_attached) return;
    _attached = true;
    coord.connection.states.listen(_onState);
    // `cancel` from anyone: no continuation for that media any more.
    coord.connection.feeds.listen((f) {
      final id = coord.serverState.peek()?.mediaId;
      if (f.action == 'advance-cancel' && id != null) _hiddenFor.value = id;
    });
    effect(() {
      final next = coord.nextEpisode.value;
      final plan = coord.jellyfinPlan.value;
      unawaited(_loadContinuation(next, plan));
    });
    // What continues this media becomes known (the next episode found, a
    // file of ours up): add it.
    effect(() {
      coord.nextEpisode.value;
      coord.ownFile.value;
      untracked(() => _continue(coord.serverState.peek()));
    });
    // The state decides what to get ready; the media playing having
    // started (or sitting out) lets the preload go.
    effect(() {
      coord.settledMediaId.value;
      coord.selfAway.value;
      final r = coord.serverState.value;
      untracked(() => _warm(r));
    });
  }

  // ------------------------------------------------------------- adding

  /// Adds [pick] to Up next (at the end, or with [next] right after what
  /// plays). A link is probed first and refused like Put it up when it
  /// will not play. Returns an error text, or null when sent.
  Future<String?> add(PickedMedia pick, {bool next = false}) async {
    coord.markInput();
    if (coord.serverState.peek() == null) return 'not in a server';
    if (coord.stateStale.peek()) return 'reconnecting — add it again once back';
    if (items.peek().length >= RelayConstants.maxQueueItems) {
      return 'Up next is full (${RelayConstants.maxQueueItems} items)';
    }
    final ({QueueItem item, Uint8List? thumb}) built;
    try {
      final b = await _build(pick);
      if (b is String) return b;
      built = b as ({QueueItem item, Uint8List? thumb});
    } catch (e) {
      return "couldn't add it: $e";
    }
    final item = built.item;
    if (item.key.isNotEmpty) _local[item.key] = (pick: pick, at: DateTime.now());
    final thumb = built.thumb;
    coord.connection.sendQueue(QueueIntent.add(item, next: next, thumb: thumb == null ? '' : base64Encode(thumb)));
    coord.notify(AddedToUpNext(item.title));
    return null;
  }

  /// A continuation episode becomes an Up next item.
  Future<String?> promote(EpisodeLink e) => add(e.pick);

  /// The item, or an error text.
  Future<Object> _build(PickedMedia pick) async {
    switch (pick) {
      case JellyfinMedia():
        final accounts = coord.jellyfin;
        if (accounts.account(pick.serverId) == null) return 'that Jellyfin server is not linked any more';
        if (accounts.statusOf(pick.serverId) == JellyfinAccountStatus.expired) {
          return 'Jellyfin sign-in expired — reconnect it in Settings → Jellyfin & integrations';
        }
        final client = accounts.clientFor(pick.serverId);
        final thumb = client == null ? null : await _jellyfinThumb(client, pick.itemId);
        return (
          item: QueueItem(
            media: mediaForPick(pick),
            how: QueueHow.jellyfin,
            title: pick.title,
            sub: pick.subtitle,
            duration: (pick.runtime?.inMilliseconds ?? 0) / 1000,
          ),
          thumb: thumb,
        );
      case FileMedia(:final path):
        final file = File(path);
        if (!await file.exists()) return 'file not found — check the path';
        final name = pick.label;
        final parsed = parseReleaseName(name);
        final shot = await thumbnailFor(path);
        Uint8List? thumb;
        if (shot != null) {
          try {
            final bytes = await File(shot.imagePath).readAsBytes();
            if (bytes.length <= RelayConstants.maxPosterBytes) thumb = bytes;
          } catch (_) {}
        }
        // The library's name for it when it knows the show (what friends
        // see in Up next), else the release name's.
        final what = coord.fileRef?.call(path);
        final ep = what != null && what.kind == 'episode'
            ? (refEpisodeLine(what) ?? '').replaceAll(' ', '')
            : [
                if (parsed.season != null) 'S${parsed.season}',
                if (parsed.episode != null) 'E${parsed.episode}',
                if (parsed.episode == null) ?parsed.extra,
              ].join();
        final title = what != null && what.title.isNotEmpty ? what.title : parsed.series.trim();
        return (
          item: QueueItem(
            media: HelloMedia(name: name, size: await file.length(), duration: 0, ref: what),
            how: QueueHow.file,
            title: title.isEmpty ? name : title,
            sub: ep,
            duration: (shot?.duration.inMilliseconds ?? 0) / 1000,
            key: _newKey(),
          ),
          thumb: thumb,
        );
      case LinkMedia(:final url, :final anyway):
        // Alone, a link plays direct: there is nobody to pass it on to.
        final relay = coord.alone.peek() ? LinkRelay.direct : pick.relay;
        final linked = await mediaForLink(coord.jellyfin, url);
        final ref = linked.jellyfin;
        if (ref != null) {
          return (
            item: QueueItem(
                media: linked,
                how: QueueHow.jellyfin,
                title: ref.title.isEmpty ? linked.name : ref.title,
                sub: ref.subtitle ?? '',
                duration: ref.runtimeSecs ?? 0),
            thumb: null,
          );
        }
        LinkProbe? probe;
        String? probeError;
        try {
          probe = await coord.ytDlp.probe(url).timeout(const Duration(seconds: 45));
        } catch (e) {
          probeError = '$e';
        }
        final problem = probe == null ? playErrorText(probeError ?? '') : probe.problem;
        if (problem != null && !anyway) return problem;
        if (relay == LinkRelay.me) {
          if (probe == null) return problem ?? "couldn't reach the site";
          final relayProblem = probe.relayProblem;
          if (relayProblem != null) return relayProblem;
        }
        if (relay == LinkRelay.server && !coord.serverHasPassword) return 'server fetch needs a server password';
        if (relay == LinkRelay.server && probe != null && probe.isPage && probe.info != null) {
          final relayProblem = probe.relayProblem;
          if (relayProblem != null) return relayProblem;
        }
        final uri = Uri.tryParse(url) ?? Uri();
        final info = probe?.info;
        final title = probe?.title ?? linked.name;
        final site = info == null
            ? uri.host
            : (info.uploader.isNotEmpty ? info.uploader : (info.extractor.isNotEmpty ? info.extractor : uri.host));
        final thumbUrl = info?.thumbnail == null ? null : Uri.tryParse(info!.thumbnail!);
        final thumb = thumbUrl == null ? null : (await thumbnailArt(thumbUrl))?.poster;
        final how = switch (relay) {
          LinkRelay.direct => QueueHow.direct,
          LinkRelay.server => QueueHow.server,
          LinkRelay.me => QueueHow.through,
        };
        return (
          item: QueueItem(
            media: HelloMedia(
                name: title,
                size: 0,
                duration: 0,
                url: how == QueueHow.through ? null : url,
                relay: how == QueueHow.server ? const MediaRelay(fetch: true) : null,
                ref: linkMediaRef(title)),
            how: how,
            title: title,
            sub: site,
            duration: info?.duration ?? 0,
            key: how == QueueHow.through ? _newKey() : '',
          ),
          thumb: thumb,
        );
    }
  }

  String _newKey() => [for (var i = 0; i < 12; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  /// A wide picture of a Jellyfin item: an episode's own still, else the
  /// item's (or series') thumb or backdrop, else its poster.
  Future<Uint8List?> _jellyfinThumb(JellyfinClient client, String itemId) async {
    try {
      final item = await client.item(itemId).timeout(const Duration(seconds: 10));
      final ref = (item.kind == JellyfinItemKind.episode ? item.ownImage(JellyfinImageType.primary) : null) ??
          item.image(JellyfinImageType.thumb) ??
          item.image(JellyfinImageType.backdrop) ??
          item.image(JellyfinImageType.primary);
      if (ref == null) return null;
      return await fetchImage(
          client.imageUrl(ref, maxWidth: 480, quality: 80), client.authHeaders, RelayConstants.maxPosterBytes);
    } catch (e) {
      debugPrint('queue: no Jellyfin picture for $itemId: $e');
      return null;
    }
  }

  /// [item]'s link as this app may hand it out (Copy link, Open in
  /// browser): a link everyone opens (it is in the state), or a link this
  /// app passes on (its adder). Null otherwise: a server-fetched link stays
  /// with the server, another member's passed-on link with them.
  String? linkOf(QueueItem item) => switch (item.how) {
        QueueHow.direct => item.media.url,
        QueueHow.through when item.by == _me => switch (_local[item.key]?.pick) {
            LinkMedia(:final url) => url,
            _ => null,
          },
        _ => null,
      };

  /// [item]'s page on its Jellyfin server, when that server is linked here.
  String? jellyfinPageOf(QueueItem item) {
    final ref = item.media.jellyfin;
    return ref == null ? null : coord.jellyfin.webUrlOf(ref.serverId, ref.itemId);
  }

  // ------------------------------------------------------------ editing

  void move(String id, int to) {
    coord.markInput();
    coord.connection.sendQueue(QueueIntent.move(id, to));
  }

  void remove(String id) {
    coord.markInput();
    coord.connection.sendQueue(QueueIntent.remove(id));
  }

  /// Plays [id] now: this app puts it up when it is the one that can,
  /// else it asks the server, and the app that can puts it up.
  void playNow(String id) {
    coord.markInput();
    final r = coord.serverState.peek();
    final item = r?.queue.where((q) => q.id == id).firstOrNull;
    if (r == null || item == null) return;
    if (queuePerformer(item, r.members).id == _me) {
      _perform(item);
    } else {
      coord.connection.sendQueue(QueueIntent.play(id));
    }
  }

  /// Plays what comes next now (Up next's first item, else the
  /// continuation).
  void skip() {
    final first = head.peek();
    if (first != null) playNow(first.id);
  }

  /// Cancel on the end card: the countdown stops for everyone, and the
  /// continuation goes (`cancel`).
  void cancelCountdown() {
    coord.markInput();
    coord.connection.sendQueue(const QueueIntent.cancel());
  }

  /// "Clear" under "Continues with": the continuation of what plays goes
  /// for everyone (`cancel`) and does not come back for this media.
  void clearContinuation() {
    final id = coord.serverState.peek()?.mediaId;
    if (id != null) _hiddenFor.value = id;
    cancelCountdown();
  }

  /// The further episodes of [continuation] (after the one that continues
  /// what plays), unless it was cleared for the media playing.
  late final Computed<List<EpisodeLink>> shownContinuation = computed(() {
    final id = coord.serverState.value?.mediaId;
    if (id == null || _hiddenFor.value == id) return const <EpisodeLink>[];
    final auto = continues.value?.media.jellyfin?.itemId;
    return [for (final e in continuation.value) if (e.item.id != auto) e];
  });

  // --------------------------------------------------------- per state

  void _onState(StateBroadcast r) {
    _lastState = r;
    // What played came back after a restart under a new mediaId: a
    // continuation cleared for it stays cleared.
    if (_restoreFrom != -1 && r.media != null && _hiddenFor.peek() == _restoreFrom) _hiddenFor.value = r.mediaId;
    _prune(r);
    // The server asks for an item (a countdown ran out, Play now from
    // another app, nothing up yet): the app that puts it up does.
    final play = r.queuePlay;
    if (play != null) {
      final item = r.queue.where((q) => q.id == play).firstOrNull;
      if (item != null && queuePerformer(item, r.members).id == _me) _perform(item);
    }
    _syncCountdown(r);
    _continue(r);
    _warm(r);
  }

  /// Forgets what no longer matters: performing marks after a minute (a
  /// swap that never landed may be tried again), local picks no longer
  /// queued.
  void _prune(StateBroadcast r) {
    final now = DateTime.now();
    _performing.removeWhere((_, at) => now.difference(at) > const Duration(minutes: 1));
    final keys = {for (final q in r.queue) q.key};
    // Kept while a restarted server waits for what played: Up next comes
    // back with it.
    if (_restoreFrom == -1) {
      _local.removeWhere((k, v) => !keys.contains(k) && now.difference(v.at) > const Duration(minutes: 1));
    }
  }

  /// The end card from the server's state: the media ended with something
  /// next; the seconds of `state.advance` move on with a 1 s timer.
  void _syncCountdown(StateBroadcast r) {
    final head = r.queue.firstOrNull;
    if (r.transport != 'finished' || head == null || r.media == null) {
      _timer?.cancel();
      _timer = null;
      if (countdown.peek() != null) countdown.value = null;
      return;
    }
    final a = r.advance != null && r.advance!.id == head.id ? r.advance : null;
    int? left;
    String? waiting;
    if (a != null) {
      left = advanceSecondsLeft(a, coord.connection.serverNow());
      if (left == 0 && queuePerformer(head, r.members).id == null) {
        waiting = r.members.where((m) => m.id == head.by).firstOrNull?.name ?? head.byName;
      }
    }
    countdown.value = UpNextCountdown(mediaId: r.mediaId, item: head, secondsLeft: left, waitingFor: waiting);
    if (a == null) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        final now = coord.serverState.peek();
        if (now != null) _syncCountdown(now);
      });
    }
  }

  // ------------------------------------------------------------ restart

  /// The server restarted without media; what played ([mediaId]) is being
  /// offered back (-1: that is over).
  void restoreFrom(int mediaId) => _restoreFrom = mediaId;

  /// What played is back after a server restart: Up next as [before] had
  /// it comes back too. The app whose offer won ([winner]) adds the items
  /// anyone can put up (links everyone opens, Jellyfin items); every app
  /// its own links passed on and files (only it has them; [self] is its
  /// member id then). A server-fetched link's address stayed with the old
  /// server, so it is gone; the continuation comes back as usual.
  void restoreAfterRestart(StateBroadcast before, String self, {required bool winner}) {
    for (final q in before.queue) {
      if (q.auto) continue;
      final ok = switch (q.how) {
        QueueHow.direct || QueueHow.jellyfin => winner,
        QueueHow.through || QueueHow.file => self.isNotEmpty && q.by == self && _local.containsKey(q.key),
        QueueHow.server => false,
      };
      if (!ok) continue;
      final local = _local[q.key];
      if (local != null) _local[q.key] = (pick: local.pick, at: DateTime.now());
      final thumb = thumbs.bytesFor(q.thumb);
      coord.connection.sendQueue(QueueIntent.add(
          QueueItem(media: q.media, how: q.how, title: q.title, sub: q.sub, duration: q.duration, key: q.key),
          thumb: thumb == null ? '' : base64Encode(thumb)));
    }
    _restoreFrom = -1;
  }

  // ------------------------------------------------------- continuation

  /// Adds what continues the media playing (`auto`, PROTOCOL.md "Queue")
  /// when this app may ([mayAddContinuation]: it put it up, or that
  /// member is not in and this is the first who is), knows what comes
  /// next, and it is not there or cancelled yet; with the setting on. A
  /// Jellyfin episode played with this app's account continues with the
  /// series' next one, a file this app put up with the next episode of its
  /// show in the library (numbers skipped on the way said in its line).
  void _continue(StateBroadcast? r) {
    if (r == null || r.media == null || !coord.settings.autoAdvance.peek()) return;
    final id = r.mediaId;
    if (_continuedFor == id || _hiddenFor.peek() == id) return;
    if (r.queue.any((q) => q.auto && q.forMedia == id)) {
      _continuedFor = id;
      return;
    }
    final swapBy = r.media?['swapBy'];
    if (!mayAddContinuation(_me, swapBy is String ? swapBy : null, r.members)) return;
    final ref = refOfStateMedia(r.media);
    final next = coord.nextEpisode.peek();
    if (ref != null) {
      if (next == null || !sameJellyfinItem(ref, coord.currentRef.peek())) return;
      _continuedFor = id;
      unawaited(_addContinuation(id, next.pick));
      return;
    }
    final own = coord.ownFile.peek();
    final finder = coord.nextFile;
    if (own == null || own.$1 != id || finder == null) return;
    _continuedFor = id;
    unawaited(() async {
      try {
        final n = await finder(own.$2);
        if (n == null) return;
        final gap = n.skipped;
        await _addContinuation(id, FileMedia(n.episode.path),
            note: gap == null ? null : 'skips ${gap.label}');
      } catch (e) {
        debugPrint('queue: what continues ${own.$2}: $e');
      }
    }());
  }

  Future<void> _addContinuation(int mediaId, PickedMedia pick, {String? note}) async {
    try {
      final b = await _build(pick);
      if (b is! ({QueueItem item, Uint8List? thumb})) return;
      final r = coord.serverState.peek();
      if (r == null || r.mediaId != mediaId || _hiddenFor.peek() == mediaId) return;
      final sub = [b.item.sub, ?note].where((s) => s.isNotEmpty).join('  ·  ');
      final item = b.item.copyWith(auto: true, forMedia: mediaId, sub: sub);
      if (item.key.isNotEmpty) _local[item.key] = (pick: pick, at: DateTime.now());
      final thumb = b.thumb;
      coord.connection.sendQueue(QueueIntent.add(item, thumb: thumb == null ? '' : base64Encode(thumb)));
    } catch (e) {
      debugPrint('queue: adding what continues media $mediaId: $e');
    }
  }

  /// Puts [item] up from here (once per item while it is in flight).
  /// When it cannot play after all, it is taken off with the reason.
  void _perform(QueueItem item) {
    if (_performing.containsKey(item.id)) return;
    _performing[item.id] = DateTime.now();
    unawaited(() async {
      String? error;
      try {
        error = await _swapTo(item);
      } catch (e) {
        error = '$e';
      }
      if (error != null) {
        debugPrint('queue: ${item.id} cannot go up: $error');
        coord.connection.sendQueue(QueueIntent.remove(item.id, why: "couldn't play it ($error)"));
      }
    }());
  }

  Future<String?> _swapTo(QueueItem item) async {
    switch (item.how) {
      case QueueHow.jellyfin:
        final ref = item.media.jellyfin;
        final pick = ref == null ? null : pickForRef(coord.jellyfin, ref);
        if (pick == null) return 'no Jellyfin account here for it';
        coord.swapJellyfin(pick, queueId: item.id);
        return null;
      case QueueHow.direct:
        final url = item.media.url;
        if (url == null) return 'no link';
        // Each viewer opens it: one computer's probe does not decide.
        return coord.swapLink(url, relay: LinkRelay.direct, anyway: true, queueId: item.id);
      case QueueHow.server:
        coord.swapQueued(HelloMedia(name: item.title, size: 0, duration: 0, relay: const MediaRelay(fetch: true)),
            item.id,
            art: thumbs.bytesFor(item.thumb));
        return null;
      case QueueHow.through:
      case QueueHow.file:
        final local = _local[item.key];
        if (local == null) return "it isn't on this computer any more";
        // Only this app can pass it on, and a member sitting out has
        // nothing open: back first.
        if (coord.selfAway.peek()) coord.joinBack();
        return coord.swapPicked(local.pick, queueId: item.id);
    }
  }

  // ------------------------------------------------------------ warming

  /// How long a warm result is kept, when it is resolved again, and when a
  /// failed one is tried again.
  static const _warmKeep = Duration(minutes: 35);
  static const _warmRefresh = Duration(minutes: 30);
  static const _warmRetry = Duration(minutes: 2);

  String _warmKey = '';
  String? _warmUrl;
  Timer? _warmTimer;
  int _warmGen = 0;
  // What the preload player should hold once the media playing has
  // started (null: nothing); [_preloadFresh]: open it again (a link's
  // refresh).
  ({String url, Map<String, String>? headers})? _preloadWant;
  bool _preloadFresh = false;
  String _preloadKey = '';
  bool _preloadBusy = false;
  bool _preloadOk = true;
  int _preloadGen = 0;
  StateBroadcast? _lastState;

  bool _ownAccount(String serverId) =>
      coord.jellyfin.account(serverId) != null && coord.jellyfin.statusOf(serverId) != JellyfinAccountStatus.expired;

  /// What this app gets ready: the first item of the queue (Up next's,
  /// else the continuation). Every app does, each its own copy (see
  /// [_WarmTarget]); while sitting out only the probe of a link this app
  /// puts up (its swap reads it). Null: nothing.
  _WarmTarget? _warmTarget(StateBroadcast? r) {
    final t = _warmTargetHere(r);
    if (t == null || !coord.selfAway.peek()) return t;
    return t.probe == null ? null : _WarmTarget(t.id, probe: t.probe);
  }

  _WarmTarget? _warmTargetHere(StateBroadcast? r) {
    if (r == null) return null;
    final head = r.queue.firstOrNull;
    if (head != null) {
      final performer = queuePerformer(head, r.members).id == _me;
      final local = _local[head.key]?.pick;
      // The server's warm relay of the item, once bytes can flow: what
      // everyone without their own copy preloads.
      final relay = head.media.relay;
      final warmUrl = relay != null && relay.live ? coord.media.warmRelayUrl(head, relay) : null;
      switch (head.how) {
        case QueueHow.jellyfin:
          final ref = head.media.jellyfin;
          if (ref == null) return null;
          if (_ownAccount(ref.serverId)) return _WarmTarget(head.id, ref: ref);
          // No account here: the server's login passes it on (`/j`), else
          // the warm relay a member with an account feeds.
          final open = r.relayNext ? coord.jellyfinRelayUrl(ref) : warmUrl;
          return open == null ? null : _WarmTarget(head.id, open: open);
        case QueueHow.direct:
          final url = head.media.url;
          if (url == null) return null;
          return _WarmTarget(head.id, probe: performer ? url : null, open: url);
        case QueueHow.through:
          // Only its adder has the link (and feeds the warm relay).
          if (!performer) return warmUrl == null ? null : _WarmTarget(head.id, open: warmUrl);
          final url = local is LinkMedia ? local.url : null;
          return _WarmTarget(head.id, probe: url, open: url);
        case QueueHow.file:
          if (!performer) return warmUrl == null ? null : _WarmTarget(head.id, open: warmUrl);
          // The host's own file plays from its `/m` URL once it is up.
          return _WarmTarget(head.id, open: local is FileMedia && coord.hostFile == null ? local.path : null);
        case QueueHow.server:
          // The server fetches it into its warm relay; everyone preloads that.
          if (warmUrl != null) return _WarmTarget(head.id, open: warmUrl);
          return performer ? _WarmTarget(head.id) : null;
      }
    }
    return null;
  }

  /// Keeps the one item that plays next ready on this app, so a skip or
  /// the end of what plays starts it at once: a link probed when this app
  /// puts it up (`AppYtDlp.probe`, kept while it stays first), a Jellyfin
  /// item resolved with this app's account
  /// ([SessionCoordinator.warmJellyfin]), and then opened in the hidden
  /// preload player ([MediaPipeline.prepare]) once the media
  /// playing has started. Done as soon as it is first, again before that
  /// runs out, dropped when it is no longer first.
  void _warm(StateBroadcast? r) {
    _feedWarm(r);
    final t = _warmTarget(r);
    final key = t?.key ?? '';
    if (key != _warmKey) {
      _dropWarm(r);
      _warmKey = key;
      if (t == null) {
        if (warm.peek() != null) warm.value = null;
      } else if (t.empty) {
        warm.value = (id: t.id, state: WarmState.ready);
      } else {
        warm.value = (id: t.id, state: WarmState.warming);
        _resolveWarm(t, fresh: false);
      }
    }
    _syncPreload(r);
  }

  // The warm relay this app feeds (`<queue id>|<token>`), started once.
  String _fedWarm = '';

  /// Feeds the server's warm relay of Up next's first item from here when
  /// it names this member as its source (a link passed on, a file), or a
  /// Jellyfin item this app puts up with its own account when the server
  /// asks for a source; see [RelayFeeder.feedWarm]. The server
  /// drops the relay (and with it the source) once the item is no longer
  /// first.
  void _feedWarm(StateBroadcast? r) {
    final head = r?.queue.firstOrNull;
    final relay = head?.media.relay;
    if (r == null || head == null || relay == null || relay.fetch) return;
    final key = '${head.id}|${coord.connection.token}';
    if (key == _fedWarm) return;
    switch (head.how) {
      case QueueHow.through:
      case QueueHow.file:
        if (relay.source != _me) return;
        final pick = _local[head.key]?.pick;
        if (pick is FileMedia) {
          _fedWarm = key;
          coord.media.feeder.feedWarm(head.id, RelayMedia.single(FileRelayBytes(File(pick.path))));
        } else if (pick is LinkMedia) {
          _fedWarm = key;
          unawaited(() async {
            try {
              // The probe [_resolveWarm] keeps: no second yt-dlp run.
              final probe = await coord.ytDlp.probe(pick.url, keep: _warmKeep).timeout(const Duration(seconds: 60));
              final y = await coord.ytDlp.ytDlp;
              if (_fedWarm != key) return;
              coord.media.feeder.feedWarm(head.id, LinkRelayMedia(Uri.parse(pick.url), ytDlp: y, probe: probe));
            } catch (e) {
              debugPrint('queue: feeding ${head.id}: $e');
            }
          }());
        }
      case QueueHow.jellyfin:
        final ref = head.media.jellyfin;
        if (ref == null || (relay.source.isNotEmpty && relay.source != _me)) return;
        if (queuePerformer(head, r.members).id != _me) return;
        // Resolved with this app's account by [_resolveWarm].
        final w = coord.warmJellyfin;
        if (w == null || !sameJellyfinItem(w.ref, ref)) return;
        _fedWarm = key;
        coord.media.feeder.feedWarm(
            head.id, RelayMedia.single(HttpRelayBytes(Uri.parse(w.plan.url), headers: w.plan.headers)));
      case QueueHow.direct:
      case QueueHow.server:
        return;
    }
  }

  void _dropWarm(StateBroadcast? r) {
    _warmTimer?.cancel();
    _warmTimer = null;
    _warmGen++;
    _preloadWant = null;
    final url = _warmUrl;
    _warmUrl = null;
    if (url != null) coord.ytDlp.release(url);
    // Kept while it is what just went up: that open takes it.
    final w = coord.warmJellyfin;
    if (w != null && !sameJellyfinItem(w.ref, refOfStateMedia(r?.media))) coord.warmJellyfin = null;
  }

  void _resolveWarm(_WarmTarget t, {required bool fresh}) {
    final gen = ++_warmGen;
    unawaited(() async {
      var ok = true;
      ({String url, Map<String, String>? headers})? open;
      try {
        final probe = t.probe, ref = t.ref, url = t.open;
        if (probe != null) {
          _warmUrl = probe;
          final p = await coord.ytDlp.probe(probe, keep: _warmKeep, fresh: fresh).timeout(const Duration(seconds: 60));
          ok = p.problem == null;
        }
        if (ref != null) {
          final plan = await resolveJellyfinRef(coord.jellyfin, ref, relay: false, relayUrl: null);
          if (gen != _warmGen) return;
          ok = plan is OwnPlay;
          if (plan is OwnPlay) {
            coord.warmJellyfin = (ref: ref, plan: plan, until: DateTime.now().add(_warmKeep));
            open = (url: plan.url, headers: plan.headers);
            _feedWarm(coord.serverState.peek());
          }
        } else if (url != null && ok) {
          open = (url: url, headers: null);
        }
      } catch (e) {
        ok = false;
        debugPrint('queue: getting ${t.id} ready: $e');
      }
      if (gen != _warmGen) return;
      _preloadWant = ok ? open : null;
      // A refresh opens a link again (a page's stream URLs expire); the
      // same Jellyfin stream stays as it is.
      _preloadFresh = fresh && ok && t.ref == null && open != null;
      final waits = ok && open != null && coord.media.preloadEnabled;
      warm.value = (id: t.id, state: !ok ? WarmState.failed : (waits ? WarmState.warming : WarmState.ready));
      _syncPreload(coord.serverState.peek());
      _warmTimer = Timer(ok ? _warmRefresh : _warmRetry, () => _resolveWarm(t, fresh: true));
    }());
  }

  /// Puts [_preloadWant] in the preload player, or drops what it holds;
  /// only once the media playing has started (its own open goes first,
  /// and a preload a swap is about to take is never replaced before), at
  /// once while sitting out (nothing preloads then).
  void _syncPreload(StateBroadcast? r) {
    // The newest state seen here: the coordinator's lags behind while the
    // same `state` is still being handed to it.
    final seen = _lastState;
    if (r == null || (seen != null && seen.mediaId > r.mediaId)) r = seen;
    if (r == null) return;
    final out = coord.selfAway.peek();
    if (!out && r.media != null && coord.settledMediaId.peek() != r.mediaId) return;
    final want = out ? null : _preloadWant;
    final media = coord.media;
    if (want == null) {
      _preloadKey = '';
      _preloadGen++;
      if (media.preloadUrl != null) unawaited(media.dropPrepared());
      return;
    }
    if (!media.preloadEnabled) return;
    final key = '${want.url}|${want.headers}';
    final fresh = _preloadFresh;
    // Asked for already: in flight, there, or failed (tried again with the
    // next refresh). One that went away (Reload video) is asked again.
    if (!fresh && key == _preloadKey && (_preloadBusy || !_preloadOk || media.preloadUrl == want.url)) return;
    _preloadFresh = false;
    _preloadKey = key;
    _preloadBusy = true;
    final gen = ++_preloadGen;
    final id = warm.peek()?.id;
    unawaited(coord.media.prepare(want.url, headers: want.headers, fresh: fresh).then((ok) {
      if (gen != _preloadGen) return;
      _preloadBusy = false;
      _preloadOk = ok;
      // A preload that fails leaves the usual open: nothing to say.
      if (!ok) debugPrint('queue: preload of $id failed');
      final w = warm.peek();
      if (w != null && w.id == id && w.state == WarmState.warming) {
        warm.value = (id: w.id, state: WarmState.ready);
      }
    }));
  }

  // -------------------------------------------------------- continuation

  /// The next few episodes after the one playing (own account only).
  Future<void> _loadContinuation(EpisodeLink? next, JellyfinPlan? plan) async {
    if (next == null || plan is! OwnPlay) {
      _continuationFor = '';
      if (continuation.peek().isNotEmpty) continuation.value = const [];
      return;
    }
    final key = '${plan.account.serverId}/${next.item.id}';
    if (key == _continuationFor) return;
    _continuationFor = key;
    continuation.value = [next];
    final seriesId = next.item.seriesId;
    if (seriesId == null) return;
    try {
      final list = await coord.jellyfin.cached(
          plan.account.serverId, 'episodes:$seriesId', () => plan.client.episodes(seriesId));
      if (_continuationFor != key) return;
      final more = [next];
      var at = next.item;
      while (more.length < 4) {
        final after = episodeAfter(list, at.id);
        if (after == null) break;
        more.add(EpisodeLink(after, pickFor(plan.account, after)));
        at = after;
      }
      continuation.value = more;
    } catch (e) {
      debugPrint('queue: continuation of $seriesId: $e');
    }
  }
}

/// What [QueueController] gets ready for one item on this app: [probe] a
/// link (the app that puts it up), resolve [ref] with this app's own
/// account, and preload [open] (or the resolved stream). None of it:
/// nothing to do here, and it is ready ([empty]).
class _WarmTarget {
  final String id;
  final String? probe;
  final JellyfinRef? ref;
  final String? open;
  const _WarmTarget(this.id, {this.probe, this.ref, this.open});

  bool get empty => probe == null && ref == null && open == null;
  String get key => '$id|$probe|$open|${ref?.serverId}/${ref?.itemId}/${ref?.mediaSourceId}';
}
