import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'constants.dart';
import 'logging.dart';

// Diagnostics sharing (ARCHITECTURE "Logging", PROTOCOL "Diagnostics"):
// each app sends its log lines to the server, which merges them with its
// own into one session log. The batch format both sides use, and the
// app's sender.

/// One log record of a member: [t] in epoch ms (the app's clock while it
/// waits, the server's on the wire), the level name, the logger and the
/// redacted message (an error and stack trace on the lines below).
class DiagLine {
  final int t;
  final String level;
  final String logger;
  final String message;
  const DiagLine({required this.t, required this.level, required this.logger, required this.message});

  /// Roughly its bytes in a batch.
  int get size => message.length + logger.length + level.length + 32;

  Map<String, Object?> toJson() => {'t': t, 'l': level, 'n': logger, 'm': message};

  static DiagLine? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['t'], l = j['l'], n = j['n'], m = j['m'];
    if (t is! num || !t.isFinite || m is! String) return null;
    return DiagLine(t: t.toInt(), level: l is String ? l : 'INFO', logger: n is String ? n : 'app', message: m);
  }
}

/// A "Mark a problem" from a member: when (epoch ms, server clock) and
/// its optional note.
class DiagMark {
  final int t;
  final String note;
  const DiagMark({required this.t, this.note = ''});

  Map<String, Object?> toJson() => {'t': t, if (note.isNotEmpty) 'note': note};

  static DiagMark? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['t'], note = j['note'];
    if (t is! num || !t.isFinite) return null;
    return DiagMark(t: t.toInt(), note: note is String ? note : '');
  }
}

/// The body of `POST /l/<sid>/<token>` (gzip of its JSON): the app's
/// [version], whether it [share]s its lines (false: none, the server notes
/// it once), the [lines], how many it [dropped] since the last batch (its
/// buffer was full) and any problem [marks].
class DiagBatch {
  final String version;
  final bool share;
  final List<DiagLine> lines;
  final int dropped;
  final List<DiagMark> marks;
  const DiagBatch({this.version = '', this.share = true, this.lines = const [], this.dropped = 0, this.marks = const []});

  Map<String, Object?> toJson() => {
        if (version.isNotEmpty) 'v': version,
        if (!share) 'share': false,
        if (lines.isNotEmpty) 'lines': [for (final l in lines) l.toJson()],
        if (dropped > 0) 'dropped': dropped,
        if (marks.isNotEmpty) 'marks': [for (final m in marks) m.toJson()],
      };

  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));

  factory DiagBatch.fromJson(Map<String, Object?> j) {
    final lines = j['lines'], marks = j['marks'], dropped = j['dropped'], v = j['v'];
    return DiagBatch(
      version: v is String ? v : '',
      share: j['share'] != false,
      lines: lines is List ? lines.map(DiagLine.fromJson).whereType<DiagLine>().toList() : const [],
      dropped: dropped is num && dropped.isFinite && dropped > 0 ? dropped.toInt() : 0,
      marks: marks is List ? marks.map(DiagMark.fromJson).whereType<DiagMark>().toList() : const [],
    );
  }

  /// Unpacks a body; throws [FormatException] when it is not gzip of a
  /// batch or unpacks to more than [maxBytes].
  static DiagBatch decode(List<int> body, {int maxBytes = RelayConstants.diagDecodedBytes}) {
    final text = utf8.decode(gunzipCapped(body, maxBytes), allowMalformed: true);
    final j = jsonDecode(text);
    if (j is! Map) throw const FormatException('not a batch');
    return DiagBatch.fromJson(Map<String, Object?>.from(j));
  }
}

/// [body] gunzipped, or [FormatException] once it passes [maxBytes] (a
/// small body must not unpack to gigabytes).
List<int> gunzipCapped(List<int> body, int maxBytes) {
  final out = BytesBuilder(copy: false);
  final sink = _CappedSink(out, maxBytes);
  try {
    gzip.decoder.startChunkedConversion(sink)
      ..add(body)
      ..close();
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('not gzip: $e');
  }
  return out.takeBytes();
}

class _CappedSink implements Sink<List<int>> {
  final BytesBuilder out;
  final int max;
  _CappedSink(this.out, this.max);

  @override
  void add(List<int> data) {
    if (out.length + data.length > max) throw const FormatException('too large');
    out.add(data);
  }

  @override
  void close() {}
}

/// Where the app's lines go: the server's base URL (`http://host:port`),
/// this member's token and the server's clock minus the local one (ms).
typedef DiagTarget = ({Uri base, String token, double offsetMs});

/// The app's side: keeps its log records (not the hosted server's, which
/// the server logs itself) while in a session, and sends them to the
/// server every [RelayConstants.diagIntervalSecs] ([tick]) and on [stop].
/// [target] is null while there is nowhere to send (reconnecting, no
/// clock sample yet): lines wait, up to [bufferBytes], the oldest dropped
/// and counted. With [share] off nothing is kept or sent but one batch
/// saying so per connection; problem marks ([markProblem]) go either way.
class DiagUploader {
  final DiagTarget? Function() target;
  /// The app and its version, e.g. `Starsync 1.4.0 on linux`.
  final String version;
  final int bufferBytes;
  final int batchBytes;
  final Duration interval;
  final DateTime Function() _now;
  DiagUploader({
    required this.target,
    required this.version,
    this.bufferBytes = RelayConstants.diagBufferBytes,
    this.batchBytes = RelayConstants.diagBatchBytes,
    this.interval = const Duration(seconds: RelayConstants.diagIntervalSecs),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Loggers never sent: the hosted server's records (`server.*`, the
  /// server logs them itself) and the local copy of a mark ([markLogger]).
  static bool sends(String logger) => logger != 'server' && !logger.startsWith('server.') && logger != markLogger;

  /// The local log's copy of a problem mark.
  static const markLogger = 'problem';
  static final _markLog = Logger(markLogger);

  final _lines = Queue<DiagLine>();
  var _size = 0;
  var _dropped = 0;
  final _marks = <DiagMark>[];
  StreamSubscription<LogRecord>? _sub;
  HttpClient? _http;
  var _busy = false;
  var _again = false;
  DateTime? _last;
  /// The token the server was told "doesn't share" for.
  String? _toldOff;
  var _share = true;

  bool get running => _sub != null;

  static final _running = <DiagUploader>{};
  static final _carried = <DiagLine>[];

  /// Logs [message] on [logger] (INFO, or WARNING with [warning]); with no uploader running
  /// (out of a session) the line also waits for the next one that
  /// [start]s, so startup findings reach a session log too.
  static void carry(String logger, String message, {bool warning = false}) {
    final level = warning ? Level.WARNING : Level.INFO;
    Logger(logger).log(level, message);
    if (_running.isNotEmpty || !sends(logger)) return;
    if (_carried.length >= 50) _carried.removeAt(0);
    _carried.add(DiagLine(
        t: DateTime.now().millisecondsSinceEpoch, level: level.name, logger: logger, message: redactLog(message)));
  }

  /// [flushSoon] on every running uploader: a player opens, switches or
  /// goes, the app closes or stalled (a crash there must not take the
  /// last 10 s of lines with it).
  static void flushAllSoon() {
    for (final u in _running.toList()) {
      u.flushSoon();
    }
  }

  /// The least time between two [flushSoon] posts (the server takes 30 a
  /// minute per member; a refused one waits for the next).
  static const urgentGap = Duration(seconds: 2);
  DateTime? _urgentAt;
  Timer? _urgentTimer;

  /// Sends what waits now, or once [urgentGap] after the last such send.
  void flushSoon() {
    if (_sub == null || _urgentTimer != null) return;
    final t = _now(), at = _urgentAt;
    final wait = at == null ? Duration.zero : urgentGap - t.difference(at);
    if (wait <= Duration.zero) {
      _urgentAt = t;
      unawaited(flush());
      return;
    }
    _urgentTimer = Timer(wait, () {
      _urgentTimer = null;
      _urgentAt = _now();
      if (_sub != null) unawaited(flush());
    });
  }

  /// Lines waiting to go.
  int get pending => _lines.length;

  /// Share the log lines (Settings); off drops what waits.
  bool get share => _share;
  set share(bool on) {
    if (on == _share) return;
    _share = on;
    if (!on) _clear();
    _toldOff = null;
  }

  /// Starts keeping the log's records (a session starts).
  void start() {
    _sub ??= Logger.root.onRecord.listen(_onRecord);
    _last = _now();
    _running.add(this);
    if (_share) {
      for (final l in _carried) {
        add(l);
      }
    }
    _carried.clear();
  }

  void _onRecord(LogRecord r) {
    if (!_share || !sends(r.loggerName)) return;
    final b = StringBuffer(r.message);
    if (r.error != null) b.write('\n  error: ${r.error}');
    final s = '${r.stackTrace ?? ''}'.trimRight();
    if (s.isNotEmpty) b.write('\n$s');
    add(DiagLine(t: r.time.millisecondsSinceEpoch, level: r.level.name, logger: r.loggerName, message: redactLog('$b')));
  }

  /// Keeps [line] (local clock) for the next batch.
  void add(DiagLine line) {
    _lines.add(line);
    _size += line.size;
    _trim();
  }

  void _trim() {
    while (_size > bufferBytes && _lines.isNotEmpty) {
      _size -= _lines.removeFirst().size;
      _dropped++;
    }
  }

  void _clear() {
    _lines.clear();
    _size = 0;
    _dropped = 0;
  }

  /// "Mark a problem": a marker line in the server's session log with
  /// [note] (cut to [RelayConstants.maxProblemNoteLength], one line), sent
  /// now with the lines waiting. Also written to the local log. True once
  /// the server has it; false when it waits (not connected).
  Future<bool> markProblem(String note) {
    var clean = note.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
    if (clean.length > RelayConstants.maxProblemNoteLength) {
      clean = clean.substring(0, RelayConstants.maxProblemNoteLength);
    }
    _markLog.warning('=== PROBLEM marked${clean.isEmpty ? '' : ': $clean'} ===');
    _marks.add(DiagMark(t: _now().millisecondsSinceEpoch, note: redactLog(clean)));
    return flush();
  }

  /// Once a second (the app's ticker): sends when [interval] has passed.
  void tick() {
    final last = _last;
    if (last != null && _now().difference(last) < interval) return;
    unawaited(flush());
  }

  /// Sends what waits: true when the server took all of it (or there was
  /// nothing to send).
  Future<bool> flush() async {
    if (_busy) {
      // Once the one under way is done (a mark goes now, not next tick).
      _again = true;
      return false;
    }
    final tg = target();
    if (tg == null) return false;
    _busy = true;
    _last = _now();
    try {
      final offset = tg.offsetMs.round();
      List<DiagMark> takeMarks() {
        final m = [for (final x in _marks) DiagMark(t: x.t + offset, note: x.note)];
        _marks.clear();
        return m;
      }

      if (!_share) {
        if (_toldOff == tg.token && _marks.isEmpty) return true;
        final marks = takeMarks();
        final ok = await _post(tg, DiagBatch(version: version, share: false, marks: marks));
        if (ok) {
          _toldOff = tg.token;
        } else {
          _marks.insertAll(0, [for (final m in marks) DiagMark(t: m.t - offset, note: m.note)]);
        }
        return ok;
      }
      // A few batches at most per flush; the rest goes next time.
      for (var i = 0; i < 8 && (_lines.isNotEmpty || _marks.isNotEmpty || _dropped > 0); i++) {
        final taken = <DiagLine>[];
        var bytes = 0;
        while (_lines.isNotEmpty && (taken.isEmpty || bytes + _lines.first.size <= batchBytes)) {
          final l = _lines.removeFirst();
          _size -= l.size;
          bytes += l.size;
          taken.add(l);
        }
        final dropped = _dropped;
        _dropped = 0;
        final marks = takeMarks();
        final batch = DiagBatch(
          version: version,
          lines: [for (final l in taken) DiagLine(t: l.t + offset, level: l.level, logger: l.logger, message: l.message)],
          dropped: dropped,
          marks: marks,
        );
        if (!await _post(tg, batch)) {
          // Back in front, in order; the cap applies again.
          for (final l in taken.reversed) {
            _lines.addFirst(l);
            _size += l.size;
          }
          _dropped += dropped;
          _marks.insertAll(0, [for (final m in marks) DiagMark(t: m.t - offset, note: m.note)]);
          _trim();
          return false;
        }
      }
      return _lines.isEmpty;
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        if (_sub != null) unawaited(flush());
      }
    }
  }

  static Uri _httpUri(Uri base, String path, [Map<String, String>? query]) => base.replace(
      scheme: base.scheme == 'wss' || base.scheme == 'https' ? 'https' : 'http',
      path: path,
      queryParameters: query,
      fragment: null);

  /// The server's `http://host:port` for a `/sync` socket URL.
  static Uri baseOf(Uri wsUri) => _httpUri(wsUri, '/');

  Future<bool> _post(DiagTarget tg, DiagBatch batch) async {
    try {
      final http = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await http.postUrl(_httpUri(tg.base, '/l/default/${tg.token}')).timeout(const Duration(seconds: 5));
      final body = batch.encode();
      req.headers.contentType = ContentType('application', 'gzip');
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      // 413: this batch can never go (should not happen); drop it.
      return res.statusCode == 204 || res.statusCode == 200 || res.statusCode == 413;
    } catch (_) {
      return false;
    }
  }

  /// The server's session log of the last [hours] (every member and the
  /// server, merged), or null when it cannot be had (not connected, a
  /// server without one, an older server).
  Future<String?> fetchSessionLog({int hours = 6}) async {
    final tg = target();
    if (tg == null) return null;
    try {
      final http = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await http
          .getUrl(_httpUri(tg.base, '/l/default/${tg.token}', {'hours': '$hours'}))
          .timeout(const Duration(seconds: 5));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final bytes = <int>[];
      await for (final c in res.timeout(const Duration(seconds: 30))) {
        bytes.addAll(c);
      }
      if (res.statusCode != 200) return null;
      return utf8.decode(gunzipCapped(bytes, 64 << 20), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// The session ends: what waits goes now (best effort, [timeout]), then
  /// nothing is kept until the next [start].
  Future<void> stop({Duration timeout = const Duration(milliseconds: 1500)}) async {
    await _sub?.cancel();
    _sub = null;
    _running.remove(this);
    _urgentTimer?.cancel();
    _urgentTimer = null;
    if ((_lines.isNotEmpty || _marks.isNotEmpty || _dropped > 0) && target() != null) {
      try {
        await flush().timeout(timeout);
      } catch (_) {}
    }
    _clear();
    _marks.clear();
    _toldOff = null;
    _last = null;
    _http?.close(force: true);
    _http = null;
  }
}
