import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';

// Crash and freeze evidence the app collects itself (ARCHITECTURE
// "Logging"): a marker while it runs (a start that finds one says the last
// run did not close cleanly; on Windows, with the system's crash records
// of it), and a watch on the event loop.

const _logger = 'crash';
final _log = createLogger(_logger);

File? _marker;

/// Looks for the last run's marker in [folder], logs an unclean end (on
/// Windows with its crash records, in the background) and writes this
/// run's marker. Never throws.
void startCrashWatch(String folder, {required String version}) {
  try {
    final f = File('$folder${Platform.pathSeparator}running.json');
    _marker = f;
    if (f.existsSync()) {
      Map<String, Object?> last = const {};
      try {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) last = Map<String, Object?>.from(j);
      } catch (_) {}
      final when = last['started'] ?? '?';
      final closing = last['closing'] != null ? ', while closing' : '';
      DiagUploader.carry(_logger,
          'previous run ended without a clean close$closing: ${last['version'] ?? '?'}, started $when, pid ${last['pid'] ?? '?'}',
          warning: true);
      if (Platform.isWindows) unawaited(_windowsCrashes());
    }
    _write(f, {'version': version, 'started': DateTime.now().toUtc().toIso8601String(), 'pid': pid});
  } catch (e) {
    _log.warning('crash marker: $e');
  }
}

/// The close started: an end from here on is a close that did not finish.
void crashWatchClosing() {
  final f = _marker;
  if (f == null) return;
  try {
    final j = jsonDecode(f.readAsStringSync());
    if (j is Map) _write(f, {...j, 'closing': DateTime.now().toUtc().toIso8601String()});
  } catch (_) {}
}

/// A clean close: the marker goes.
void crashWatchClean() {
  try {
    _marker?.deleteSync();
  } catch (_) {}
  _marker = null;
}

void _write(File f, Map<Object?, Object?> j) {
  try {
    f.writeAsStringSync(jsonEncode(j), flush: true);
  } catch (e) {
    _log.warning('crash marker: $e');
  }
}

// ------------------------------------------------------- Windows records

/// The Application log's crash (1000, 1001) and hang (1002) records of
/// the last [days] days, newest first.
String windowsCrashQuery({int days = 3}) =>
    '*[System[(EventID=1000 or EventID=1001 or EventID=1002) and TimeCreated[timediff(@SystemTime) <= ${days * 86400000}]]]';

Future<void> _windowsCrashes() async {
  try {
    final r = await Process.run('wevtutil', ['qe', 'Application', '/q:${windowsCrashQuery()}', '/c:30', '/rd:true', '/f:xml'],
            stdoutEncoding: const SystemEncoding())
        .timeout(const Duration(seconds: 5));
    if (r.exitCode != 0) {
      DiagUploader.carry(_logger, 'windows crash records: wevtutil exit ${r.exitCode}');
      return;
    }
    final found = parseWindowsCrashes('${r.stdout}');
    if (found.isEmpty) {
      DiagUploader.carry(_logger, 'windows crash records: none for $appExe in the last 3 days');
    }
    for (final c in found.take(5)) {
      DiagUploader.carry(_logger, 'windows crash record: $c', warning: true);
    }
  } catch (e) {
    DiagUploader.carry(_logger, 'windows crash records: not read ($e)');
  }
}

const appExe = 'starsync.exe';

/// One crash or hang record of the app from the Windows event log.
class WindowsCrash {
  final int id;
  final String time;
  final Map<String, String> fields;
  const WindowsCrash(this.id, this.time, this.fields);

  @override
  String toString() {
    final f = fields.entries.where((e) => e.value.isNotEmpty).map((e) => '${e.key}=${e.value}').join(' ');
    final kind = switch (id) { 1000 => 'crash', 1001 => 'report', 1002 => 'hang', _ => 'event' };
    return '$kind ($id) at $time $f';
  }
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&')
    .trim();

/// The app's records in `wevtutil qe ... /f:xml` output: the EventData
/// values (not the localized description), by position since older
/// Windows leave them unnamed.
List<WindowsCrash> parseWindowsCrashes(String xml) {
  final out = <WindowsCrash>[];
  for (final ev in RegExp(r'<Event[\s>][\s\S]*?</Event>').allMatches(xml)) {
    final e = ev[0]!;
    final id = int.tryParse(RegExp(r'<EventID[^>]*>(\d+)</EventID>').firstMatch(e)?[1] ?? '');
    if (id == null) continue;
    final time = RegExp(r'''<TimeCreated\s+SystemTime=['"]([^'"]+)['"]''').firstMatch(e)?[1] ?? '?';
    final data = [
      for (final d in RegExp(r'<Data(?:\s[^>]*?)?(?:/>|>([\s\S]*?)</Data>)').allMatches(e)) _unescape(d[1] ?? ''),
    ];
    String at(int i) => i < data.length ? data[i] : '';
    final Map<String, String> fields;
    switch (id) {
      case 1000:
        if (at(0).toLowerCase() != appExe) continue;
        fields = {
          'version': at(1),
          'module': at(3),
          'moduleVersion': at(4),
          'exception': at(6),
          'offset': at(7),
        };
      case 1001:
        // Windows Error Reporting: bucket, type, event name, response, cab
        // id, then P1 (the app) to P10.
        if (at(5).toLowerCase() != appExe) continue;
        fields = {
          'event': at(2),
          'version': at(6),
          if (at(2) == 'APPCRASH') ...{'module': at(8), 'exception': at(11), 'offset': at(12)} else 'p4': at(8),
        };
      case 1002:
        if (at(0).toLowerCase() != appExe) continue;
        fields = {'version': at(1), 'hangType': at(9)};
      default:
        continue;
    }
    out.add(WindowsCrash(id, time, fields));
  }
  return out;
}

// ---------------------------------------------------------- event loop

Timer? _stallTimer;

/// A 1 s timer that logs when it fires more than [limit] late: the UI
/// isolate was blocked (or the machine slept), not the network.
void startStallWatch({Duration limit = const Duration(seconds: 3)}) {
  if (_stallTimer != null) return;
  final sw = Stopwatch()..start();
  var last = sw.elapsed;
  _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    final t = sw.elapsed;
    final late = t - last - const Duration(seconds: 1);
    last = t;
    if (late > limit) {
      _log.warning('event loop stalled: the 1 s timer fired ${(late.inMilliseconds / 1000).toStringAsFixed(1)} s late');
      DiagUploader.flushAllSoon();
    }
  });
}
