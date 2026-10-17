import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:sync_relay_core/core.dart';

import 'media_endpoint.dart' show resolveMediaRequest;
import 'relay_buffer.dart';
import 'relay_routes.dart' show relayBudgets, writeRelayRange;

// The single-fetch source: the member who passes a link on reads it from
// the site once. Per track, one [RelayBuffer] filled by one sequential
// upstream reader ([LocalRelayFeed] over [ResumingBytes]) serves two
// readers: this app's own player, through a loopback HTTP endpoint
// ([SharedSource.playerUrl]), and the server's pulls
// ([SharedSource.upload], handed to the relay's [RelaySource]). The two
// are kept within one window ([RelayBuffer.together]). Byte tracks only:
// a page with pieces tracks (HLS/DASH) keeps the two fetches.

final _log = createLogger('relay');

/// Upstream errors worth another try after a pause: a cut connection, a
/// timeout, a 5xx, and the refusals a CDN gives a client it thinks is too
/// busy (412, 429). 403/410 (an expired URL) is the page's job
/// ([PageRelayMedia] resolves again once); anything else is final.
bool retryableUpstream(Object e) {
  if (e is UpstreamHttpException) return e.status == 412 || e.status == 429 || e.status >= 500;
  return e is HttpException || e is SocketException || e is TimeoutException;
}

/// [inner] read with resume: a read that breaks goes on from the byte it
/// reached. After a cut that brought bytes it goes on after 100 ms; after
/// an answer without a byte (a refusal, a dead connection) after
/// [backoff] (attempt n, reset by any byte). A read that brings nothing
/// for [stall] is cut and resumed the same way. It fails only on a final
/// error or after [giveUp] without a byte. Cancelling stops it at once,
/// also during a pause.
class ResumingBytes implements RelayBytes {
  final RelayBytes inner;
  final Duration Function(int attempt) backoff;
  final Duration giveUp;
  final Duration stall;
  ResumingBytes(this.inner,
      {Duration Function(int attempt)? backoff,
      this.giveUp = const Duration(seconds: 60),
      this.stall = const Duration(seconds: 20)})
      : backoff = backoff ?? defaultBackoff;

  static final _rnd = Random();

  /// 0.5 s doubling to 8 s, with up to 25% jitter.
  static Duration defaultBackoff(int attempt) {
    final ms = min(8000, 500 * (1 << min(attempt, 4)));
    return Duration(milliseconds: ms + _rnd.nextInt(ms ~/ 4 + 1));
  }

  /// Resumes so far, for logs and tests.
  int retries = 0;

  /// Bytes read from [inner], for logs and tests.
  int bytesIn = 0;

  @override
  Future<int> size() async {
    var attempt = 0;
    final since = DateTime.now();
    while (true) {
      try {
        return await inner.size();
      } catch (e) {
        if (!retryableUpstream(e) || DateTime.now().difference(since) > giveUp) rethrow;
        retries++;
        await Future<void>.delayed(backoff(attempt++));
      }
    }
  }

  @override
  Stream<List<int>> read(int start, int end) {
    late final StreamController<List<int>> out;
    var cancelled = false;
    StreamSubscription<List<int>>? sub;
    Completer<void>? pause;
    Future<void> run() async {
      var pos = start, attempt = 0;
      var lastByte = DateTime.now();
      while (!cancelled && pos <= end) {
        var got = 0;
        final done = Completer<Object?>();
        Timer? quiet;
        void watch() {
          quiet?.cancel();
          quiet = Timer(stall, () {
            if (done.isCompleted) return;
            unawaited(sub?.cancel().catchError((_) {}));
            done.complete(TimeoutException('upstream sent nothing', stall));
          });
        }

        watch();
        sub = inner.read(pos, end).listen((c) {
          if (done.isCompleted) return;
          pos += c.length;
          got += c.length;
          bytesIn += c.length;
          lastByte = DateTime.now();
          watch();
          out.add(c);
        }, onError: (Object e) {
          if (!done.isCompleted) done.complete(e);
        }, onDone: () {
          if (!done.isCompleted) done.complete(null);
        }, cancelOnError: true);
        final err = await done.future;
        quiet?.cancel();
        sub = null;
        if (cancelled) return;
        if (err == null) {
          if (pos <= end) continue; // ended short without an error: go on
          break;
        }
        if (!retryableUpstream(err) || DateTime.now().difference(lastByte) > giveUp) {
          out.addError(err);
          break;
        }
        // A cut after some bytes goes on almost at once (what mpv's
        // reconnect does); an answer without a byte backs off, doubling.
        if (got > 0) attempt = 0;
        final wait = got > 0 ? const Duration(milliseconds: 100) : backoff(attempt++);
        retries++;
        _log.fine('upstream read broke at $pos ($err); again in ${wait.inMilliseconds} ms');
        final p = pause = Completer<void>();
        final t = Timer(wait, () {
          if (!p.isCompleted) p.complete();
        });
        await p.future;
        t.cancel();
        pause = null;
      }
      if (!cancelled) await out.close();
    }

    out = StreamController<List<int>>(
      onListen: () => unawaited(run()),
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        cancelled = true;
        final p = pause;
        if (p != null && !p.isCompleted) p.complete();
        await sub?.cancel().catchError((_) {});
      },
    );
    return out.stream;
  }

  @override
  Future<void> close() => inner.close();
}

/// A media a [SharedSource] cannot share (a pieces track): the caller
/// keeps the player and the relay on their own fetches.
class SharedSourceUnsupported implements Exception {
  final String reason;
  const SharedSourceUnsupported(this.reason);
  @override
  String toString() => reason;
}

/// One track of a [SharedSource]: its buffer and its single upstream
/// reader.
class SharedTrack {
  final String kind;
  final int size;
  final RelayBuffer buffer;
  final LocalRelayFeed feed;
  final ResumingBytes upstream;
  SharedTrack(this.kind, this.size, this.buffer, this.feed, this.upstream);
}

/// A media read from upstream once and served to this app's player and to
/// the relay. [open] opens it (a page's tracks, the loopback endpoint) and
/// starts reading the tracks' sizes; [ready] completes with them. The
/// player can open [playerUrl] right after [open]: the endpoint waits for
/// the sizes. Nothing is read upstream while neither reader asks.
class SharedSource {
  final RelayMedia media;

  /// The local buffer's budgets (all tracks together, split by size like
  /// the server's, [relayBudgets]). It only has to hold what the player
  /// and the upload have not both read yet: they read within [ahead] of
  /// each other ([RelayBuffer.together]).
  final int ahead, back;
  final Duration Function(int attempt)? backoff;

  /// A read waiting for missing bytes gives up after this.
  final Duration waitLimit;
  SharedSource(this.media,
      {this.ahead = RelayConstants.sharedAheadBytes,
      this.back = RelayConstants.sharedBackBytes,
      this.backoff,
      this.waitLimit = const Duration(seconds: RelayConstants.relayWaitSecs)});

  /// The tracks, once [ready].
  final tracks = <SharedTrack>[];
  List<RelayTrack> _upstream = const [];
  HttpServer? _http;
  final _secret = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  Future<void>? _opening;
  final _ready = Completer<void>();
  var _closed = false;

  /// Opens the media and binds the loopback endpoint; the sizes are read
  /// meanwhile ([ready]). Throws [SharedSourceUnsupported] for a media
  /// with pieces tracks, or why the media cannot be opened.
  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    final upstream = await media.open();
    if (upstream.any((t) => t.bytes == null)) {
      throw const SharedSourceUnsupported('a segmented stream (HLS/DASH) is not shared');
    }
    _upstream = upstream;
    final http = _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) => unawaited(_serve(req)), onError: (_) {});
    // Nobody may be waiting on [ready] yet: its error is not unhandled.
    _ready.future.ignore();
    unawaited(_readSizes());
  }

  Future<void> _readSizes() async {
    final sw = Stopwatch()..start();
    try {
      final wrapped = [for (final t in _upstream) ResumingBytes(t.bytes!, backoff: backoff)];
      final sizes = await Future.wait([for (final w in wrapped) w.size()]);
      if (_closed) throw const RelayEnded();
      final budgets = relayBudgets(sizes, ahead: ahead, back: back);
      var ids = 0;
      for (var i = 0; i < _upstream.length; i++) {
        final b = RelayBuffer(
            ahead: budgets[i].$1,
            back: budgets[i].$2,
            waitLimit: waitLimit,
            together: (playerViewer, uploadViewer),
            nextId: () => ++ids);
        final f = LocalRelayFeed(RelayTrack(_upstream[i].kind, wrapped[i]), b);
        b.attach(f, sizes[i]);
        tracks.add(SharedTrack(_upstream[i].kind, sizes[i], b, f, wrapped[i]));
      }
      _log.info('shared source: ${tracks.map((t) => '${t.kind.isEmpty ? 'file' : t.kind} ${t.size} bytes').join(' + ')} '
          'in ${sw.elapsedMilliseconds} ms, the player on loopback port ${_http?.port}');
      _ready.complete();
    } catch (e, st) {
      _ready.completeError(e, st);
    }
  }

  /// Completes once every track's size is known; throws why it could not
  /// be read.
  Future<void> get ready => _ready.future;

  /// [open], then [ready].
  Future<void> start() async {
    await open();
    await ready;
  }

  /// The two readers' names in each track's [RelayBuffer].
  static const playerViewer = 'player', uploadViewer = 'upload';

  /// What this app's own player opens (after [open]): one loopback URL, or
  /// an mpv EDL of one per track. No headers: the site's stay in this
  /// process.
  String get playerUrl {
    final http = _http;
    if (http == null) throw StateError('shared source not open');
    final urls = [for (var i = 0; i < _upstream.length; i++) 'http://127.0.0.1:${http.port}/$_secret/$i'];
    return urls.length == 1 ? urls.single : mpvEdl(urls);
  }

  /// What [RelaySource] serves: the same buffers, read as the viewer
  /// `upload`. Closing it leaves the shared source open (the player may
  /// still read it).
  RelayMedia get upload => _Upload(this);

  /// Upstream reads resumed so far, all tracks (for logs and tests).
  int get resumes => tracks.fold(0, (a, t) => a + t.upstream.retries);

  /// Bytes read upstream so far, all tracks.
  int get bytesIn => tracks.fold(0, (a, t) => a + t.upstream.bytesIn);

  /// Bytes the local buffers hold now.
  int get cachedBytes => tracks.fold(0, (a, t) => a + t.buffer.cachedBytes);

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    Future<void> plain(int status, [Map<String, String> headers = const {}]) async {
      res.statusCode = status;
      headers.forEach(res.headers.set);
      res.headers.set(HttpHeaders.connectionHeader, 'close');
      await res.close().catchError((_) {});
    }

    final seg = req.uri.pathSegments;
    final i = seg.length == 2 && seg[0] == _secret ? int.tryParse(seg[1]) : null;
    if (i == null || i < 0 || i >= _upstream.length || (req.method != 'GET' && req.method != 'HEAD')) {
      return plain(404);
    }
    try {
      await ready.timeout(waitLimit);
    } catch (_) {
      return plain(_closed ? 404 : 502);
    }
    if (_closed) return plain(404);
    final t = tracks[i];
    final r = resolveMediaRequest(
        rangeHeader: req.headers.value(HttpHeaders.rangeHeader), size: t.size, filename: 'track');
    if (r.status != 200 && r.status != 206) return plain(r.status, r.headers);
    final end = r.end ?? t.size - 1;
    final Socket socket;
    try {
      socket = await res.detachSocket(writeHeaders: false);
    } catch (_) {
      return;
    }
    // The server's own answer code: headers in time, connection: close,
    // a read that breaks resets the connection (the player reconnects).
    await writeRelayRange(socket, socket, r.status, r.headers, end - r.start + 1,
        req.method == 'HEAD' ? null : t.buffer.read(playerViewer, r.start, end),
        onBroke: (e) => _log.fine('shared source: the player\'s read of track $i broke: $e'));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _http?.close(force: true);
    for (final t in tracks) {
      t.buffer.dispose();
      await t.feed.close();
    }
    if (tracks.isNotEmpty) _log.info('shared source closed: $bytesIn bytes read upstream, $resumes resumes');
    await media.close();
  }
}

class _Upload implements RelayMedia {
  final SharedSource src;
  _Upload(this.src);

  @override
  Future<List<RelayTrack>> open() async {
    await src.open();
    return [for (var i = 0; i < src._upstream.length; i++) RelayTrack(src._upstream[i].kind, _BufferBytes(src, i))];
  }

  /// The shared source owns the upstream.
  @override
  Future<void> close() async {}
}

class _BufferBytes implements RelayBytes {
  final SharedSource src;
  final int i;
  _BufferBytes(this.src, this.i);

  @override
  Future<int> size() async {
    await src.ready;
    return src.tracks[i].size;
  }

  @override
  Stream<List<int>> read(int start, int end) async* {
    await src.ready;
    if (src._closed) throw const RelayEnded();
    yield* src.tracks[i].buffer.read(SharedSource.uploadViewer, start, end);
  }

  @override
  Future<void> close() async {}
}
