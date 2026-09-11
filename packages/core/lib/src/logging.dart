import 'package:logging/logging.dart';

Logger createLogger(String name) => Logger(name);

void initLogging({Level level = Level.INFO}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen((r) {
    // ignore: avoid_print
    print('${r.time.toIso8601String()} ${r.level.name} ${r.loggerName}: ${r.message}');
    if (r.error != null) {
      // ignore: avoid_print
      print('  error: ${r.error}');
    }
    if (r.stackTrace != null) {
      // ignore: avoid_print
      print('${r.stackTrace}');
    }
  });
}
