import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart' as pkg_logging;
import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'server_hub.dart';
import 'session.dart';

// The session log (ARCHITECTURE "Logging"): every member's diagnostics
// (`POST /l/...`) and the server's own records, merged in server-clock
// order into one file per day, `session-YYYY-MM-DD.log`, in the server's
// log folder.

class _Entry {
  final int t;
  final int seq;
  final String text;
  const _Entry(this.t, this.seq, this.text);
}

/// The merged log. Lines wait [window] (members send every 10 s) and are
/// written in time order; a line later than that (a reconnect's backlog)
/// still goes in with its own time, a little out of order.
class SessionLog {
  final LogFiles files;
  final Duration window;
  final DateTime Function() _now;
  final _pending = <_Entry>[];
  var _seq = 0;
  StreamSubscription<pkg_logging.LogRecord>? _own;
  /// Per member token: the version and share state already noted.
  final _noted = <String, ({String version, bool share})>{};

  SessionLog(String dir,
      {this.window = const Duration(seconds: 15),
      List<String> shareWith = const ['app', 'server'],
      DateTime Function()? now,
      int maxFileBytes = 10 * 1024 * 1024,
      int maxTotalBytes = 100 * 1024 * 1024})
      : _now = now ?? DateTime.now,
        files = LogFiles(dir,
            prefix: sessionLogPrefix,
            shareWith: shareWith,
            maxFileBytes: maxFileBytes,
            maxTotalBytes: maxTotalBytes,
            now: now) {
    files.open();
  }

  /// Takes this isolate's own log records as the server's lines.
  void captureOwn() {
    _own ??= pkg_logging.Logger.root.onRecord.listen((r) {
      final b = StringBuffer(r.message);
      if (r.error != null) b.write('\n  error: ${r.error}');
      final s = '${r.stackTrace ?? ''}'.trimRight();
      if (s.isNotEmpty) b.write('\n$s');
      add(r.time.millisecondsSinceEpoch, 'server', r.level.name, r.loggerName, '$b');
    });
  }

  static final _control = RegExp(r'[\x00-\x08\x0b-\x1f\x7f]');
  static final _loggerName = RegExp(r'^[A-Za-z0-9_.\-]{1,40}$');
  static const _levels = {'FINEST', 'FINER', 'FINE', 'CONFIG', 'INFO', 'WARNING', 'SEVERE', 'SHOUT'};
  static const _quiet = {'FINEST', 'FINER', 'FINE', 'CONFIG', 'INFO'};

  static String _clean(String s, int max) {
    var out = s.replaceAll('\r', '').replaceAll(_control, ' ');
    if (out.length > max) out = '${out.substring(0, max)}…';
    return out;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _clock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

  /// One record at [t] (epoch ms, server clock) from [who] (`name (id)`
  /// or `server`): `HH:MM:SS.mmm [who] logger: message`, the level before
  /// the logger from WARNING up, continuation lines indented. Redacted
  /// again here.
  void add(int t, String who, String level, String logger, String message) {
    final lvl = _levels.contains(level) ? level : 'INFO';
    final name = _loggerName.hasMatch(logger) ? logger : 'app';
    final body = redactLog(_clean(message, 8192)).split('\n');
    final head = '[${_clean(who, 80).replaceAll('\n', ' ')}] ${_quiet.contains(lvl) ? '' : '$lvl '}$name: ${body.first}';
    _push(t, [head, for (final l in body.skip(1)) '  $l'].join('\n'));
  }

  /// A problem mark by [name] ([who]) at [t]:
  /// `=== PROBLEM marked by <name>: <note> ===`.
  void mark(int t, String who, String name, String note) {
    final n = redactLog(_clean(note, RelayConstants.maxProblemNoteLength).replaceAll('\n', ' ')).trim();
    _push(t, '[${_clean(who, 80).replaceAll('\n', ' ')}] === PROBLEM marked by $name${n.isEmpty ? '' : ': $n'} ===');
  }

  /// A line of the server's about a member, now.
  void note(String message) => add(_now().millisecondsSinceEpoch, 'server', 'INFO', 'diag', message);

  void _push(int t, String text) {
    final now = _now().millisecondsSinceEpoch;
    // A clock far ahead lands now; older than the files keep is dropped.
    if (t > now + 60000) t = now;
    if (t < now - files.keepDays * 86400000) return;
    _pending.add(_Entry(t, _seq++, text));
    // A flood must not grow the wait without bound: write early.
    if (_pending.length > 20000) flush(all: true);
  }

  /// Writes the lines older than [window] ([all]: every one), in order.
  /// Called every second.
  void flush({bool all = false}) {
    if (_pending.isEmpty) return;
    final until = all ? null : _now().millisecondsSinceEpoch - window.inMilliseconds;
    _pending.sort(_order);
    var n = 0;
    for (final e in _pending) {
      if (until != null && e.t > until) break;
      final at = DateTime.fromMillisecondsSinceEpoch(e.t);
      files.write('${_clock(at)} ${e.text}', at: at);
      n++;
    }
    _pending.removeRange(0, n);
  }

  static int _order(_Entry a, _Entry b) => a.t != b.t ? a.t.compareTo(b.t) : a.seq.compareTo(b.seq);

  /// A batch from the member [token] ([who] for the log, [name] for a
  /// mark): its lines, a note the first time (or when its version or
  /// sharing changes), how many it dropped, its marks.
  void takeBatch(String token, String who, String name, DiagBatch batch) {
    final version = _clean(batch.version, 100).replaceAll('\n', ' ');
    final before = _noted[token];
    if (before == null || before.version != version || before.share != batch.share) {
      _noted[token] = (version: version, share: batch.share);
      final what = version.isEmpty ? '' : ' ($version)';
      if (!batch.share) {
        note("$who doesn't share diagnostics$what");
      } else if (before == null || !before.share) {
        note('$who shares diagnostics$what');
      } else {
        note('$who now runs $version');
      }
    }
    if (batch.share) {
      for (final l in batch.lines) {
        add(l.t, who, l.level, l.logger, l.message);
      }
      if (batch.dropped > 0) {
        final t = batch.lines.isEmpty ? _now().millisecondsSinceEpoch : batch.lines.first.t;
        add(t, who, 'WARNING', 'diag', '${batch.dropped} lines dropped (the app could not send them in time)');
      }
    }
    for (final m in batch.marks) {
      mark(m.t, who, name, m.note);
    }
  }

  /// The lines of the last [since], written and waiting, oldest first; at
  /// most about [maxBytes], the newest kept.
  String recent(Duration since, {int maxBytes = 8 * 1024 * 1024}) {
    final from = _now().subtract(since);
    final fromDay = _day(from);
    final out = <String>[];
    final head = RegExp(r'^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) ');
    for (final f in files.files()) {
      final name = f.uri.pathSegments.last;
      final day = name.substring(sessionLogPrefix.length + 1, sessionLogPrefix.length + 11);
      if (day.compareTo(fromDay) < 0) continue;
      final date = DateTime.tryParse(day);
      if (date == null) continue;
      List<String> lines;
      try {
        lines = const LineSplitter().convert(utf8.decode(f.readAsBytesSync(), allowMalformed: true));
      } catch (_) {
        continue;
      }
      var keep = false;
      for (final l in lines) {
        final m = head.firstMatch(l);
        if (m != null) {
          final t = DateTime(date.year, date.month, date.day, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
              int.parse(m[4]!));
          keep = !t.isBefore(from);
        }
        if (keep) out.add(l);
      }
    }
    final fromMs = from.millisecondsSinceEpoch;
    final waiting = [..._pending]..sort(_order);
    for (final e in waiting) {
      if (e.t >= fromMs) out.add('${_clock(DateTime.fromMillisecondsSinceEpoch(e.t))} ${e.text}');
    }
    var size = 0, start = out.length;
    while (start > 0 && size + out[start - 1].length + 1 <= maxBytes) {
      size += out[--start].length + 1;
    }
    return out.sublist(start).join('\n');
  }

  static String _day(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

  Future<void> close() async {
    await _own?.cancel();
    _own = null;
    flush(all: true);
    files.close();
  }
}

class _Rate {
  var start = DateTime.now();
  var posts = 0;
  var bytes = 0;
}

/// `POST /l/<sid>/<token>`: a member's diagnostics batch ([DiagBatch],
/// gzip) into the [sessionLog]; `GET /l/<sid>/<token>?hours=N`: the session log of
/// the last N hours (gzip text), for any member. Without one (a
/// server with no log folder, the solo session) batches are taken and
/// dropped, and the GET is 404.
void mountSessionLogRoutes(RelicApp app, ServerHub hub, SessionLog? Function() sessionLog) {
  Response status(int code, [String? why]) => Response(code, body: Body.fromString(why ?? 'status $code'));
  final rates = <String, _Rate>{};

  ViewerToken? member(Request req) {
    final session = hub.sessions.get(req.pathParameters.raw[#sid] ?? '');
    final token = req.pathParameters.raw[#token] ?? '';
    if (session == null || session.gate(token) != MediaGate.ok) return null;
    return session.tokens[token];
  }

  app.post('/l/:sid/:token', (final req) async {
    final viewer = member(req);
    if (viewer == null) return status(401);
    final body = BytesBuilder(copy: false);
    try {
      await for (final c in req.read(maxLength: RelayConstants.diagBatchBytes)) {
        body.add(c);
      }
    } catch (_) {
      return status(413);
    }
    final DiagBatch batch;
    try {
      batch = DiagBatch.decode(body.takeBytes());
    } on FormatException catch (e) {
      return status(e.message == 'too large' ? 413 : 400, 'bad batch');
    }
    final now = DateTime.now();
    if (rates.length > 500) rates.removeWhere((k, _) => !hub.session.tokens.containsKey(k));
    final rate = rates.putIfAbsent(viewer.token, _Rate.new);
    if (now.difference(rate.start) >= const Duration(minutes: 1)) {
      rate
        ..start = now
        ..posts = 0
        ..bytes = 0;
    }
    final size = batch.lines.fold<int>(0, (a, l) => a + l.size);
    if (rate.posts >= RelayConstants.diagPostsPerMin || rate.bytes + size > RelayConstants.diagBytesPerMin) {
      return Response(429,
          body: Body.fromString('too many'), headers: Headers.build((h) => h['retry-after'] = ['30']));
    }
    rate
      ..posts += 1
      ..bytes += size;
    final log = sessionLog();
    if (log == null) return Response.noContent();
    log.takeBatch(viewer.token, hub.who(viewer.token), viewer.name, batch);
    return Response.noContent();
  });

  app.get('/l/:sid/:token', (final req) {
    if (member(req) == null) return status(401);
    final log = sessionLog();
    if (log == null) return status(404, 'this server keeps no session log');
    final hours = (int.tryParse(req.url.queryParameters['hours'] ?? '') ?? 6).clamp(1, 24 * 7);
    final text = log.recent(Duration(hours: hours));
    return Response.ok(
      body: Body.fromData(Uint8List.fromList(gzip.encode(utf8.encode(text))),
          mimeType: MimeType('application', 'gzip')),
      headers: Headers.build((h) => h['cache-control'] = ['no-store']),
    );
  });
}
