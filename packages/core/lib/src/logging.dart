import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

// One log for the app (its hosted server's records included) and one for
// the dedicated server: every record goes through [redactLog] once, then
// to the console and, once [startLogFiles] ran, to a rotating file
// (ARCHITECTURE "Logging").

Logger createLogger(String name) => Logger(name);

/// The server's combined log of every member and itself
/// (`session-YYYY-MM-DD.log`, ARCHITECTURE "Logging").
const sessionLogPrefix = 'session';

var _listening = false;
var _console = true;
LogFiles? _files;
// Lines logged before the files are open (the app finds its folder only
// after Flutter is up): written first once they are.
final _early = <String>[];
const _earlyMax = 2000;

/// The open log files, once [startLogFiles] ran.
LogFiles? get logFiles => _files;

/// Routes every log record to the console ([console]) and, after
/// [startLogFiles], to the files. Safe to call again (only [level] and
/// [console] change).
void initLogging({Level level = Level.INFO, bool console = true}) {
  Logger.root.level = level;
  _console = console;
  if (_listening) return;
  _listening = true;
  Logger.root.onRecord.listen((r) =>
      writeLogLine(formatLogLine(r.time, r.level.name, r.loggerName, r.message, error: r.error, stack: r.stackTrace)));
}

/// Writes the files in [dir] from now on: `<prefix>-YYYY-MM-DD.log`,
/// rotated by day and [LogFiles.maxFileBytes], pruned by age and total
/// size (shared with the session log, [sessionLogPrefix], in the same
/// folder). Lines logged before go in first. A folder that cannot be
/// written leaves logging on the console only (and says so there).
LogFiles? startLogFiles(String dir, {String prefix = 'app'}) {
  if (_files != null) return _files;
  try {
    final f = LogFiles(dir, prefix: prefix, shareWith: const [sessionLogPrefix])..open();
    _files = f;
    for (final l in _early) {
      f.write(l);
    }
    _early.clear();
    return f;
  } catch (e) {
    // ignore: avoid_print
    print('log files off: cannot write $dir ($e)');
    _early.clear();
    return null;
  }
}

/// One finished, redacted line to the console and the file.
void writeLogLine(String line) {
  if (_console) {
    // ignore: avoid_print
    print(line);
  }
  final f = _files;
  if (f != null) {
    f.write(line);
  } else if (_early.length < _earlyMax) {
    _early.add(line);
  }
}

/// `2026-10-12 18:44:27.202 WARNING relay: message`, then the error and
/// stack trace on their own lines; all of it through [redactLog].
String formatLogLine(DateTime time, String level, String logger, String message, {Object? error, Object? stack}) {
  final b = StringBuffer('${logTimestamp(time)} $level $logger: $message');
  if (error != null) b.write('\n  error: $error');
  final s = '${stack ?? ''}'.trimRight();
  if (s.isNotEmpty) b.write('\n$s');
  return redactLog(b.toString());
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Local time as the log writes it (`2026-10-12 18:44:27.202`).
String logTimestamp(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

/// The time a log line starts with, or null for a continuation line.
DateTime? logLineTime(String line) {
  final m = _lineTime.firstMatch(line);
  if (m == null) return null;
  return DateTime.tryParse('${m[1]}T${m[2]}');
}

final _lineTime = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d{3}) ');

/// A record from another isolate (the hosted server's, `LEVEL logger:
/// message`) logged here under [tag]: `server.relay` at its own level.
void relogLine(String tag, String line) {
  final m = RegExp(r'^([A-Z]+) ([^:\s]+): ').firstMatch(line);
  final level = Level.LEVELS.where((l) => l.name == m?[1]).firstOrNull;
  if (m == null || level == null) {
    Logger(tag).info(line);
    return;
  }
  Logger('$tag.${m[2]}').log(level, line.substring(m.end));
}

// ------------------------------------------------------------- redaction

// Names whose value is a secret wherever they appear as `name=value`,
// `"name":"value"` or `Name="value"` (Jellyfin's MediaBrowser header).
const _secretNames = r'(?:x-emby-token|x-mediabrowser-token|x-emby-authorization|authorization|set-cookie|cookie|'
    r'api_?key|access_?token|refresh_?token|id_?token|auth_?token|token|password|passwd|secret|host_?key|'
    r'sessdata|bili_jct|client_?secret|client_?id|client|pw)';
final _jsonSecret = RegExp('"($_secretNames)"\\s*:\\s*"(?:[^"\\\\]|\\\\.)*"', caseSensitive: false);
final _quotedSecret = RegExp('\\b($_secretNames)\\s*=\\s*"[^"]*"', caseSensitive: false);
// Header-like `Name: value` runs to the end of the line (a cookie
// header's `;`-separated pairs, MediaBrowser's comma list).
final _headerSecret = RegExp(
    '\\b(authorization|cookie|set-cookie|x-emby-authorization|x-emby-token|x-mediabrowser-token)\\s*:\\s*[^\\n]*',
    caseSensitive: false);
final _pairSecret = RegExp('\\b($_secretNames)\\s*=\\s*[^&\\s"\',;)}\\]]+', caseSensitive: false);
final _bearer = RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);
// starsync:// is an invite link (its `pw` is a server password).
final _url = RegExp(r'''\b(?:https?|wss?|starsync)://[^\s"'<>]+''', caseSensitive: false);
// A member token in a server path: /r/<sid>/<token>/..., /m, /j, /a, /i, /l.
final _pathToken = RegExp(r'(/[rmjail]/[^/\s?#]+/)[0-9a-fA-F]{32}\b');
final _userInfo = RegExp(r'^([a-z]+://)[^/@\s]+@', caseSensitive: false);

/// [s] with nothing secret left: every URL's query string down to its
/// parameter names (signed CDN links, `api_key`), user:password@ in URLs,
/// member tokens in `/r/ /m/ /j/ /a/ /i/ /l/` paths, and the values of
/// passwords, tokens, API keys, cookies, auth headers and the per-install
/// client id (`hello.client`). Applied to
/// every log line ([formatLogLine]).
String redactLog(String s) {
  if (s.isEmpty) return s;
  var out = s.replaceAllMapped(_url, (m) => _redactUrl(m[0]!));
  out = out.replaceAllMapped(_pathToken, (m) => '${m[1]}***');
  out = out.replaceAllMapped(_jsonSecret, (m) => '"${m[1]}":"***"');
  out = out.replaceAllMapped(_headerSecret, (m) => '${m[1]}: ***');
  out = out.replaceAllMapped(_quotedSecret, (m) => '${m[1]}="***"');
  out = out.replaceAllMapped(_pairSecret, (m) => '${m[1]}=***');
  out = out.replaceAllMapped(_bearer, (m) => '${m[1]} ***');
  return out;
}

String _redactUrl(String url) {
  var u = url.replaceFirstMapped(_userInfo, (m) => '${m[1]}***@');
  final hash = u.indexOf('#');
  if (hash >= 0) u = u.substring(0, hash);
  final q = u.indexOf('?');
  if (q < 0) return u;
  final names = u
      .substring(q + 1)
      .split('&')
      .map((p) => p.split('=').first)
      .where((n) => n.isNotEmpty)
      .map((n) => n.length > 40 ? '${n.substring(0, 40)}…' : n)
      .toList();
  return '${u.substring(0, q)}?${names.isEmpty ? '' : '${names.join('&')}=…'}';
}

/// [url] for a log line: scheme, host and path, the query cut to its
/// parameter names (see [redactLog]).
String logUrl(Object? url) => redactLog('$url');

// --------------------------------------------------------------- flood control

/// At most [burst] lines per key in each [window]; the next line let
/// through says how many were dropped. For floods (ffmpeg retrying a
/// refused request, a viewer's range reads).
class LogThrottle {
  final int burst;
  final Duration window;
  final DateTime Function() _now;
  final _keys = <String, ({DateTime start, int count, int dropped})>{};
  LogThrottle({this.burst = 5, this.window = const Duration(seconds: 30), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// Null to drop the line; else what to put before it: '' or
  /// `(12 more like this dropped) `.
  String? allow(String key) {
    final now = _now();
    final k = _keys[key];
    if (k == null || now.difference(k.start) >= window) {
      final dropped = k?.dropped ?? 0;
      _keys.remove(key);
      _keys[key] = (start: now, count: 1, dropped: 0);
      if (_keys.length > 500) _keys.remove(_keys.keys.first);
      return dropped > 0 ? '($dropped more like this dropped) ' : '';
    }
    if (k.count < burst) {
      _keys[key] = (start: k.start, count: k.count + 1, dropped: k.dropped);
      return '';
    }
    _keys[key] = (start: k.start, count: k.count, dropped: k.dropped + 1);
    return null;
  }
}

// ------------------------------------------------------------------ files

/// Rotating log files in [dir]: `<prefix>-YYYY-MM-DD.log` (then `.1.log`,
/// `.2.log` ... once one passes [maxFileBytes]); files older than
/// [keepDays] and the oldest beyond [maxTotalBytes] are deleted whenever a
/// file is opened. [shareWith]: other prefixes in [dir] that count toward
/// the same [maxTotalBytes] (the app's or server's log and the session
/// log); the oldest of all of them go first, never another prefix's file
/// of today (its writer may have it open).
class LogFiles {
  final String dir;
  final String prefix;
  final List<String> shareWith;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int keepDays;
  final DateTime Function() _now;
  LogFiles(this.dir,
      {this.prefix = 'app',
      this.shareWith = const [],
      this.maxFileBytes = 10 * 1024 * 1024,
      this.maxTotalBytes = 100 * 1024 * 1024,
      this.keepDays = 7,
      DateTime Function()? now})
      : _now = now ?? DateTime.now;

  RandomAccessFile? _out;
  String? _day;
  var _size = 0;
  String? _path;

  /// The file being written.
  String? get currentPath => _path;

  String _dayOf(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

  String _dayOfFile(File f) => _fileDay(prefix, f);

  static String _fileDay(String prefix, File f) =>
      f.uri.pathSegments.last.substring(prefix.length + 1, prefix.length + 11);

  /// Opens today's file (creating [dir]); throws when it cannot.
  void open() {
    Directory(dir).createSync(recursive: true);
    _roll(_dayOf(_now()));
  }

  void _roll(String day) {
    _out?.closeSync();
    _out = null;
    _day = day;
    for (var i = 0;; i++) {
      final path = '$dir${Platform.pathSeparator}$prefix-$day${i == 0 ? '' : '.$i'}.log';
      final f = File(path);
      final size = f.existsSync() ? f.lengthSync() : 0;
      if (size < maxFileBytes) {
        _out = f.openSync(mode: FileMode.append);
        _size = size;
        _path = path;
        break;
      }
    }
    prune();
  }

  /// Appends [line]; a new day or a full file moves on to the next file.
  /// [at]: the line's own time picks the day's file (else now).
  void write(String line, {DateTime? at}) {
    try {
      final day = _dayOf(at ?? _now());
      if (_out == null || day != _day || _size >= maxFileBytes) _roll(day);
      final bytes = utf8.encode('$line\n');
      _out!.writeFromSync(bytes);
      _size += bytes.length;
    } catch (_) {
      // A full disk or a removed folder must not take the app down.
    }
  }

  /// This prefix's files, oldest first.
  List<File> files() => filesOf(prefix);

  /// The files of [prefix] in [dir], oldest first.
  List<File> filesOf(String prefix) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    final name = RegExp('^${RegExp.escape(prefix)}-(\\d{4}-\\d{2}-\\d{2})(?:\\.(\\d+))?\\.log\$');
    final found = <(String, int, File)>[];
    for (final e in d.listSync()) {
      if (e is! File) continue;
      final m = name.firstMatch(e.uri.pathSegments.last);
      if (m != null) found.add((m[1]!, int.tryParse(m[2] ?? '') ?? 0, e));
    }
    found.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final f in found) f.$3];
  }

  /// Deletes files older than [keepDays], then the oldest while all of
  /// them pass [maxTotalBytes]; never the one being written.
  void prune() {
    final cutoff = _dayOf(_now().subtract(Duration(days: keepDays)));
    final kept = <File>[];
    for (final f in files()) {
      if (_dayOfFile(f).compareTo(cutoff) < 0 && f.path != _path) {
        _delete(f);
      } else {
        kept.add(f);
      }
    }
    final today = _dayOf(_now());
    // Every file under the budget, oldest day first: (day, prefix, file).
    final all = [
      for (final f in kept) (_dayOfFile(f), true, f),
      for (final p in shareWith)
        if (p != prefix)
          for (final f in filesOf(p)) (_fileDay(p, f), false, f),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var total = all.fold<int>(0, (a, f) => a + _len(f.$3));
    for (final (day, own, f) in all) {
      if (total <= maxTotalBytes) break;
      if (f.path == _path || (!own && day == today)) continue;
      total -= _len(f);
      _delete(f);
    }
  }

  static int _len(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static void _delete(File f) {
    try {
      f.deleteSync();
    } catch (_) {}
  }

  /// The lines of the last [since] (a record's continuation lines with
  /// it), oldest first; at most about [maxBytes], the newest kept.
  String recent(Duration since, {int maxBytes = 4 * 1024 * 1024}) {
    final from = _now().subtract(since);
    final fromDay = _dayOf(from);
    final out = <String>[];
    var size = 0;
    var done = false;
    for (final f in files().reversed) {
      if (done || _dayOfFile(f).compareTo(fromDay) < 0) break;
      List<String> lines;
      try {
        lines = const LineSplitter().convert(utf8.decode(f.readAsBytesSync(), allowMalformed: true));
      } catch (_) {
        continue;
      }
      // Newest first; a record's continuation lines come before its head.
      final block = <String>[];
      for (final l in lines.reversed) {
        block.add(l);
        final t = logLineTime(l);
        if (t == null) continue;
        if (t.isBefore(from)) {
          done = true;
          break;
        }
        for (final b in block) {
          size += b.length + 1;
          out.add(b);
        }
        block.clear();
        if (size >= maxBytes) {
          done = true;
          break;
        }
      }
    }
    return out.reversed.join('\n');
  }

  void close() {
    try {
      _out?.closeSync();
    } catch (_) {}
    _out = null;
  }
}
