import 'package:sync_relay_core/core.dart';

// Up next's words for an item. Who puts an item up is core's
// `queuePerformer` (whats_next.dart), read the same by the server and
// every app.

/// How [item] plays, in a few words for its row: "through Foxyz" (you:
/// "through you"), "server fetches", "everyone fetches", "Jellyfin",
/// "Foxyz's file".
String queueHowLabel(QueueItem item, {required String selfId}) {
  final mine = item.by == selfId && selfId.isNotEmpty;
  final who = mine ? 'you' : (item.byName.isEmpty ? 'who added it' : item.byName);
  return switch (item.how) {
    QueueHow.through => 'through $who',
    QueueHow.file => mine ? 'your file' : "$who's file",
    QueueHow.server => 'server fetches',
    QueueHow.direct => 'everyone fetches',
    QueueHow.jellyfin => 'Jellyfin',
  };
}

/// "1:23:45" / "23:45" for [secs]; empty when unknown.
String queueClock(double secs) {
  if (secs <= 0) return '';
  final s = secs.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
}
