import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../files/name_parser.dart';
import '../files/thumbnails.dart';
import '../jellyfin/accounts.dart';
import '../jellyfin/format.dart' show pickFor;
import '../jellyfin/session_media.dart';
import '../screens/home/picked_media.dart';
import '../session/media_art.dart';
import '../session/session_coordinator.dart';
import '../state/settings.dart';
import '../sync/avatar_cache.dart';
import 'queue_logic.dart';

// Up next on this client (see ARCHITECTURE.md "Up next"): the server's
// queue as signals, adding to it (probed, with a picture), the end-of-media
// countdown for its first item, putting an item up when this app is the
// one that can, and keeping that item ready.

/// The end-of-media card for the first Up next item. [secondsLeft] null:
/// no countdown here (auto-advance off, cancelled, or another app puts
/// it up), the card offers Play now only.
class UpNextCountdown {
  final int mediaId;
  final QueueItem item;
  final int? secondsLeft;
  const UpNextCountdown({required this.mediaId, required this.item, this.secondsLeft});
}

/// The first item's readiness, on the app that puts it up.
enum WarmState { idle, warming, ready, failed }

class QueueController {
  final SessionCoordinator coord;
  QueueController(this.coord);

  /// Queued items' pictures by hash, from `/i/`.
  late final PictureCache thumbs = PictureCache(coord.sync,
      route: 'i', keep: RelayConstants.maxQueueItems + 8, live: (s) => [for (final q in s.queue) q.thumb]);

  /// Up next, in order (empty when nothing is queued or not in a server).
  late final Computed<List<QueueItem>> items =
      computed(() => coord.serverState.value?.queue ?? const <QueueItem>[]);

  final countdown = signal<UpNextCountdown?>(null);

  /// The first item's id and how ready it is here (only on the app that
  /// puts it up; null elsewhere).
  final warm = signal<({String id, WarmState state})?>(null);

  /// The natural continuation of what plays: the next episodes of the
  /// Jellyfin series (not queued; shown greyed under Up next).
  final continuation = signal<List<EpisodeLink>>(const []);

  /// The mediaId whose continuation was cleared here.
  final _hiddenFor = signal(-1);

  /// The queue popover is open: the Up next button holds the controls up.
  final popoverOpen = signal(false);

  // What adder-only items stand for, by their key (a link passed on from
  // here, a file here). Never leaves this app.
  final Map<String, ({PickedMedia pick, DateTime at})> _local = {};
  final Map<String, DateTime> _performing = {};
  final Set<String> _skipped = {};
  int _cancelledFor = -1;
  Timer? _timer;
  bool _attached = false;
  String _continuationFor = '';
  final _random = Random.secure();

  String get _me => coord.sync.memberId;

  void attach() {
    if (_attached) return;
    _attached = true;
    coord.sync.states.listen(_onState);
    coord.sync.feeds.listen(_onFeed);
    effect(() {
      final next = coord.nextEpisode.value;
      final plan = coord.jellyfinPlan.value;
      unawaited(_loadContinuation(next, plan));
    });
    // The continuation and the state decide what to get ready.
    effect(() {
      shownContinuation.value;
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
    coord.sync.sendQueue(QueueIntent.add(item, next: next, thumb: thumb == null ? '' : base64Encode(thumb)));
    coord.showToast('Added ${item.title} to Up next');
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
        final ep = [
          if (parsed.season != null) 'S${parsed.season}',
          if (parsed.episode != null) 'E${parsed.episode}',
        ].join();
        return (
          item: QueueItem(
            media: HelloMedia(name: name, size: await file.length(), duration: 0),
            how: QueueHow.file,
            title: parsed.series.trim().isEmpty ? name : parsed.series.trim(),
            sub: ep,
            duration: (shot?.duration.inMilliseconds ?? 0) / 1000,
            key: _newKey(),
          ),
          thumb: thumb,
        );
      case LinkMedia(:final url, :final anyway):
        // Alone, a link plays direct: there is nobody to pass it on to.
        final relay = coord.solo ? LinkRelay.direct : pick.relay;
        final linked = await mediaForLink(coord.jellyfin, url);
        final ref = linked.jellyfin;
        if (ref != null) {
          return (
            item: QueueItem(
                media: HelloMedia(name: linked.name, size: 0, duration: 0, jellyfin: ref),
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
                relay: how == QueueHow.server ? const MediaRelay(fetch: true) : null),
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

  // ------------------------------------------------------------ editing

  void move(String id, int to) {
    coord.markInput();
    coord.sync.sendQueue(QueueIntent.move(id, to));
  }

  void remove(String id) {
    coord.markInput();
    coord.sync.sendQueue(QueueIntent.remove(id));
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
      coord.sync.sendQueue(QueueIntent.play(id));
    }
  }

  /// Plays the first Up next item now.
  void skip() {
    final first = items.peek().firstOrNull;
    if (first != null) playNow(first.id);
  }

  /// Cancel on the end-of-media card: no countdown here for this media.
  void cancelCountdown() {
    final c = countdown.peek();
    _timer?.cancel();
    _timer = null;
    if (c == null) return;
    _cancelledFor = c.mediaId;
    countdown.value = UpNextCountdown(mediaId: c.mediaId, item: c.item);
  }

  /// "Clear": hides the continuation of what plays now (and its next
  /// episode does not come up by itself).
  void clearContinuation() {
    final id = coord.serverState.peek()?.mediaId;
    if (id != null) _hiddenFor.value = id;
    if (coord.autoAdvance.peek() != null) coord.cancelAutoAdvance();
  }

  /// The continuation applies to [mediaId]: nothing is queued and it was
  /// not cleared.
  bool continuationShown(int mediaId) =>
      (coord.serverState.peek()?.queue.isEmpty ?? true) && _hiddenFor.peek() != mediaId;

  /// [continuation] unless cleared for the media playing.
  late final Computed<List<EpisodeLink>> shownContinuation = computed(() {
    final id = coord.serverState.value?.mediaId;
    return id != null && _hiddenFor.value == id ? const <EpisodeLink>[] : continuation.value;
  });

  // --------------------------------------------------------- per state

  void _onState(StateBroadcast r) {
    _prune(r);
    final queue = r.queue;
    final play = r.queuePlay;
    if (play != null) {
      final item = queue.where((q) => q.id == play).firstOrNull;
      if (item != null) _bringUp(item, r);
    }
    final finished = r.transport == 'finished';
    if (queue.isNotEmpty && r.media == null) {
      // Nothing up yet: the first item goes up at once.
      _bringUp(queue.first, r);
    } else if (finished && queue.isNotEmpty) {
      _atEnd(r);
    } else {
      if (countdown.peek() != null) _stopCountdown();
      if (!finished) _cancelledFor = -1;
    }
    _warm(r);
  }

  void _onFeed(FeedMessage f) {
    if (f.action == 'queue-skip') {
      coord.showToast('Skipped ${f.target ?? 'an item'}${f.reason.isEmpty ? '' : ': ${f.reason}'}');
    }
  }

  /// Forgets what no longer matters: performing marks after a minute (a
  /// swap that never landed may be tried again), local picks no longer
  /// queued.
  void _prune(StateBroadcast r) {
    final now = DateTime.now();
    _performing.removeWhere((_, at) => now.difference(at) > const Duration(minutes: 1));
    final keys = {for (final q in r.queue) q.key};
    _local.removeWhere((k, v) => !keys.contains(k) && now.difference(v.at) > const Duration(minutes: 1));
    final ids = {for (final q in r.queue) q.id};
    _skipped.removeWhere((id) => !ids.contains(id));
  }

  /// [item] should go up now: by this app when it is the one that can;
  /// nobody can: the lowest member takes it off with the reason.
  void _bringUp(QueueItem item, StateBroadcast r) {
    final perf = queuePerformer(item, r.members);
    if (perf.id == null) {
      final why = perf.why;
      if (why != null && queueJanitor(r.members) == _me && _skipped.add(item.id)) {
        coord.sync.sendQueue(QueueIntent.remove(item.id, why: why));
      }
      return;
    }
    if (perf.id == _me) _perform(item);
  }

  /// The media finished with Up next waiting: the card, and with
  /// auto-advance on the countdown, for its first item.
  void _atEnd(StateBroadcast r) {
    // Up next goes before the next episode, even one already counting.
    if (coord.autoAdvance.peek() != null) coord.cancelAutoAdvance();
    final head = r.queue.first;
    final perf = queuePerformer(head, r.members);
    if (perf.id == null && perf.why != null) {
      // Taken off by [_bringUp]'s rule; the next state shows the next one.
      _bringUp(head, r);
      return;
    }
    final c = countdown.peek();
    if (c != null && c.mediaId == r.mediaId) {
      if (c.item.id != head.id || c.item.thumb != head.thumb) {
        countdown.value = UpNextCountdown(mediaId: c.mediaId, item: head, secondsLeft: c.secondsLeft);
      }
      return;
    }
    final auto = AppSettings.instance.autoAdvance.peek() && _cancelledFor != r.mediaId;
    countdown.value = UpNextCountdown(mediaId: r.mediaId, item: head, secondsLeft: auto ? autoAdvanceSecs : null);
    _timer?.cancel();
    _timer = auto ? Timer.periodic(const Duration(seconds: 1), (_) => _tick()) : null;
  }

  void _tick() {
    final c = countdown.peek();
    final r = coord.serverState.peek();
    final left = c?.secondsLeft;
    if (c == null || left == null || r == null || r.mediaId != c.mediaId || r.transport != 'finished') {
      _stopCountdown();
      return;
    }
    if (left > 1) {
      countdown.value = UpNextCountdown(mediaId: c.mediaId, item: c.item, secondsLeft: left - 1);
      return;
    }
    _timer?.cancel();
    _timer = null;
    _cancelledFor = c.mediaId;
    countdown.value = UpNextCountdown(mediaId: c.mediaId, item: c.item);
    // Decided on the latest state: only the app that can puts it up.
    final head = r.queue.firstOrNull;
    if (head != null && queuePerformer(head, r.members).id == _me) _perform(head);
  }

  void _stopCountdown() {
    _timer?.cancel();
    _timer = null;
    countdown.value = null;
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
        coord.sync.sendQueue(QueueIntent.remove(item.id, why: "couldn't play it ($error)"));
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
        if (coord.selfOut.peek()) coord.joinBack();
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

  /// What this app gets ready: Up next's first item when it is the one
  /// that puts it up; with Up next empty, the first continuation episode
  /// (only here when this app plays the series with its own account, and
  /// its ▶ puts it up from here). Null: nothing.
  ({String id, String? url, JellyfinRef? ref})? _warmTarget(StateBroadcast? r) {
    if (r == null) return null;
    final head = r.queue.firstOrNull;
    if (head != null) {
      if (queuePerformer(head, r.members).id != _me) return null;
      final local = _local[head.key]?.pick;
      return switch (head.how) {
        QueueHow.direct => (id: head.id, url: head.media.url, ref: null),
        QueueHow.through => (id: head.id, url: local is LinkMedia ? local.url : null, ref: null),
        QueueHow.jellyfin => (id: head.id, url: null, ref: head.media.jellyfin),
        QueueHow.file || QueueHow.server => (id: head.id, url: null, ref: null),
      };
    }
    final next = shownContinuation.peek().firstOrNull;
    if (next == null) return null;
    return (id: 'next:${next.item.id}', url: null, ref: mediaForPick(next.pick).jellyfin);
  }

  /// Keeps the one item this app puts up next ready, so a skip or the end
  /// of what plays starts it at once: a link probed (`AppYtDlp.probe`,
  /// kept while it stays first), a Jellyfin item resolved with this app's
  /// account ([SessionCoordinator.warmJellyfin]). Done as soon as it is
  /// first here, again before that runs out, dropped when it is no longer
  /// first. A file or a link the server fetches has nothing to get ready.
  void _warm(StateBroadcast? r) {
    final t = _warmTarget(r);
    final ref = t?.ref;
    final key = t == null ? '' : '${t.id}|${t.url}|${ref?.serverId}/${ref?.itemId}/${ref?.mediaSourceId}';
    if (key == _warmKey) return;
    _dropWarm(r);
    _warmKey = key;
    if (t == null) {
      if (warm.peek() != null) warm.value = null;
      return;
    }
    if (t.url == null && ref == null) {
      warm.value = (id: t.id, state: WarmState.ready);
      return;
    }
    warm.value = (id: t.id, state: WarmState.warming);
    _resolveWarm(t, fresh: false);
  }

  void _dropWarm(StateBroadcast? r) {
    _warmTimer?.cancel();
    _warmTimer = null;
    _warmGen++;
    final url = _warmUrl;
    _warmUrl = null;
    if (url != null) coord.ytDlp.release(url);
    // Kept while it is what just went up: that open takes it.
    final w = coord.warmJellyfin;
    if (w != null && !sameJellyfinItem(w.ref, refOfStateMedia(r?.media))) coord.warmJellyfin = null;
  }

  void _resolveWarm(({String id, String? url, JellyfinRef? ref}) t, {required bool fresh}) {
    final gen = ++_warmGen;
    unawaited(() async {
      var ok = false;
      try {
        final url = t.url, ref = t.ref;
        if (url != null) {
          _warmUrl = url;
          final p = await coord.ytDlp.probe(url, keep: _warmKeep, fresh: fresh).timeout(const Duration(seconds: 60));
          ok = p.problem == null;
        } else if (ref != null) {
          final plan = await resolveJellyfinRef(coord.jellyfin, ref, relay: false, relayUrl: null);
          if (gen != _warmGen) return;
          if (plan is OwnPlay) {
            coord.warmJellyfin = (ref: ref, plan: plan, until: DateTime.now().add(_warmKeep));
            ok = true;
          }
        }
      } catch (e) {
        debugPrint('queue: getting ${t.id} ready: $e');
      }
      if (gen != _warmGen) return;
      warm.value = (id: t.id, state: ok ? WarmState.ready : WarmState.failed);
      _warmTimer = Timer(ok ? _warmRefresh : _warmRetry, () => _resolveWarm(t, fresh: true));
    }());
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
