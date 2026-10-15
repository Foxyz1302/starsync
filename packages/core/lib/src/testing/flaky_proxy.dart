import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Which way bytes go through a [FlakyLink]: [up] client to server,
/// [down] server to client.
enum Flow { up, down, both }

/// A TCP proxy for tests that need a bad link between a client and a
/// server (DEVELOPMENT.md "Tests"): every accepted connection is a
/// [FlakyLink] the test steers while it runs: pass through, blackhole (a
/// half-open link), added latency, a late chunk, a cut after N bytes, a
/// reset. It knows nothing about WebSocket or HTTP; a "frame" is one chunk
/// as it was read from the socket (on loopback that is usually one write,
/// e.g. one small WebSocket frame).
class FlakyProxy {
  final String upstreamHost;
  final int upstreamPort;
  final ServerSocket _server;

  /// Every connection so far, in accept order.
  final List<FlakyLink> links = [];

  /// Called with each new link before any byte goes through it, e.g. to
  /// blackhole or reset the next connection.
  void Function(FlakyLink link)? onConnect;

  final _accepted = StreamController<FlakyLink>.broadcast(sync: true);

  FlakyProxy._(this._server, this.upstreamHost, this.upstreamPort, this.onConnect) {
    _server.listen(_accept);
  }

  /// Listens on a free loopback port and forwards to
  /// [upstreamHost]:[upstreamPort].
  static Future<FlakyProxy> start(int upstreamPort,
      {String upstreamHost = '127.0.0.1', void Function(FlakyLink link)? onConnect}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return FlakyProxy._(server, upstreamHost, upstreamPort, onConnect);
  }

  /// The port clients dial instead of the server's.
  int get port => _server.port;

  /// Each new link as it is accepted.
  Stream<FlakyLink> get connections => _accepted.stream;

  /// The latest link, null before the first.
  FlakyLink? get last => links.isEmpty ? null : links.last;

  Future<void> _accept(Socket client) async {
    final link = FlakyLink._(client);
    links.add(link);
    onConnect?.call(link);
    _accepted.add(link);
    if (link.isClosed) return;
    try {
      final upstream = await Socket.connect(upstreamHost, upstreamPort);
      link._attach(upstream);
    } catch (_) {
      link._close(rst: true);
    }
  }

  /// Stops accepting and closes every link.
  Future<void> close() async {
    await _server.close();
    for (final l in links) {
      l._close(rst: false);
    }
    await _accepted.close();
  }
}

/// One proxied connection. Modes change at once and can be combined
/// ([delay] with [holdNext], say); [pass] clears them all.
class FlakyLink {
  final Socket _client;
  Socket? _upstream;
  late final _Pipe _up = _Pipe(this, Flow.up);
  late final _Pipe _down = _Pipe(this, Flow.down);
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  bool _blackholed = false;

  /// Latency added to every chunk, each way (on top of the link's own; a
  /// chunk never overtakes an earlier one).
  Duration delay = Duration.zero;

  FlakyLink._(this._client) {
    _quiet(_client);
    _client.listen(_up._onData, onDone: _up._onDone, onError: (_) => _close(rst: false));
  }

  void _attach(Socket upstream) {
    _upstream = upstream;
    _quiet(upstream);
    if (isClosed) {
      upstream.destroy();
      return;
    }
    upstream.listen(_down._onData, onDone: _down._onDone, onError: (_) => _close(rst: false));
    _ready.complete();
  }

  static void _quiet(Socket s) {
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    s.done.then((_) {}, onError: (_) {});
  }

  /// Bytes delivered client to server / server to client.
  int get bytesUp => _up.forwarded;
  int get bytesDown => _down.forwarded;

  /// Bytes swallowed by [blackhole] (and by a cut), both ways.
  int get dropped => _up.dropped + _down.dropped;

  bool get isClosed => _closed.isCompleted;

  /// Completes when the link is gone (both ends closed, a reset, a cut).
  Future<void> get closed => _closed.future;

  /// Plain pass-through again: no blackhole, delay, held chunk or cut.
  /// Bytes swallowed meanwhile stay lost (a WebSocket on it is then
  /// usually broken).
  void pass() {
    _blackholed = false;
    delay = Duration.zero;
    for (final p in [_up, _down]) {
      p._holdNext = null;
      p._cutLeft = null;
    }
  }

  /// Keeps both sockets open and drops every byte both ways, a closing
  /// end included: neither side learns anything (a half-open link, like a
  /// laptop lid closed or a NAT forgetting the flow). Chunks already
  /// delayed are dropped too.
  void blackhole() => _blackholed = true;

  bool get blackholed => _blackholed;

  /// The next chunk going [flow] (and, as TCP keeps order, everything
  /// behind it) arrives [late] later than it would.
  void holdNext(Duration late, {Flow flow = Flow.down}) {
    for (final p in _pipes(flow)) {
      p._holdNext = late;
    }
  }

  /// Delivers [bytes] more going [flow] (counted per direction; with
  /// [Flow.both] whichever gets there first), then resets the link.
  void cutAfter(int bytes, {Flow flow = Flow.both}) {
    for (final p in _pipes(flow)) {
      p._cutLeft = bytes;
    }
    if (bytes <= 0) reset();
  }

  /// Aborts both ends at once: an RST where the platform lets us ask for
  /// one (SO_LINGER 0), otherwise an abrupt close. Nothing queued is sent.
  void reset() => _close(rst: true);

  List<_Pipe> _pipes(Flow flow) => switch (flow) {
        Flow.up => [_up],
        Flow.down => [_down],
        Flow.both => [_up, _down],
      };

  void _close({required bool rst}) {
    if (isClosed) return;
    _closed.complete();
    for (final s in [_client, _upstream]) {
      if (s == null) continue;
      if (rst) _lingerZero(s);
      s.destroy();
    }
  }

  static void _lingerZero(Socket s) {
    try {
      // struct linger { int l_onoff = 1; int l_linger = 0; }
      final v = ByteData(8)
        ..setInt32(0, 1, Endian.host)
        ..setInt32(4, 0, Endian.host);
      final soLinger = Platform.isLinux || Platform.isAndroid ? 13 : 0x80;
      s.setRawOption(RawSocketOption(RawSocketOption.levelSocket, soLinger, v.buffer.asUint8List()));
    } catch (_) {}
  }

  void _bothDone() {
    if (_up._srcDone && _down._srcDone) _close(rst: false);
  }
}

class _Pipe {
  final FlakyLink link;
  final Flow flow;
  _Pipe(this.link, this.flow);

  int forwarded = 0;
  int dropped = 0;
  int? _cutLeft;
  Duration? _holdNext;
  bool _srcDone = false;
  Future<void>? _chainTail;

  Socket? get _dst => flow == Flow.up ? link._upstream : link._client;

  Future<void> get _chain => _chainTail ??= link._ready.future;

  void _then(Future<void> Function() step) {
    _chainTail = _chain.then((_) => step()).catchError((Object _) => link._close(rst: false));
  }

  void _onData(Uint8List data) {
    if (link.isClosed) return;
    if (link._blackholed) {
      dropped += data.length;
      return;
    }
    var chunk = data;
    var cut = false;
    final left = _cutLeft;
    if (left != null) {
      if (chunk.length >= left) {
        dropped += chunk.length - left;
        chunk = Uint8List.sublistView(chunk, 0, left);
        _cutLeft = 0;
        cut = true;
      } else {
        _cutLeft = left - chunk.length;
      }
    }
    var due = DateTime.now().add(link.delay);
    final hold = _holdNext;
    if (hold != null) {
      _holdNext = null;
      due = due.add(hold);
    }
    _then(() async {
      final wait = due.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (link.isClosed) return;
      if (link._blackholed) {
        dropped += chunk.length;
        return;
      }
      final dst = _dst!;
      if (chunk.isNotEmpty) {
        dst.add(chunk);
        forwarded += chunk.length;
      }
      if (cut) {
        await dst.flush();
        link.reset();
      }
    });
  }

  void _onDone() {
    _srcDone = true;
    if (link._blackholed) {
      link._bothDone();
      return;
    }
    _then(() async {
      // Half-close: the far end reads its end of stream, may still answer.
      if (!link.isClosed && !link._blackholed) unawaited(_dst?.close().then((_) {}, onError: (_) {}));
      link._bothDone();
    });
  }
}
