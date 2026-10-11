import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'server_hub.dart';

// `queue` messages (Up next, see PROTOCOL.md "Queue"): what an added item
// may carry, and the ops applied to the engine's queue.

final _key = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

bool _httpUrl(String? url) {
  final u = Uri.tryParse(url ?? '');
  return u != null && (u.isScheme('http') || u.isScheme('https')) && u.host.isNotEmpty;
}

/// An added item as the server keeps it: names cleaned like a swap's,
/// how it plays checked against what it carries, a server-fetched link's
/// URL taken out ([privateUrl]: never broadcast). Throws
/// [ProtocolException] with the reason for the sender.
({QueueItem item, String? privateUrl}) cleanQueueAdd(QueueItem raw, {required bool serverHasPassword}) {
  final media = raw.media;
  var name = sanitizeMediaName(media.name);
  final ref = media.jellyfin;
  final QueueItem item;
  String? privateUrl;
  if (ref != null || raw.how == QueueHow.jellyfin) {
    final clean = ref == null ? null : sanitizeJellyfinRef(ref);
    if (clean == null) throw const ProtocolException('bad queue item');
    if (name.isEmpty) name = clean.title;
    item = QueueItem(
        media: HelloMedia(name: name, size: 0, duration: 0, jellyfin: clean), how: QueueHow.jellyfin, title: '');
  } else {
    switch (raw.how) {
      case QueueHow.direct:
        if (!_httpUrl(media.url)) throw const ProtocolException('a queued link needs an http(s) url');
        item = QueueItem(media: HelloMedia(name: name, size: 0, duration: 0, url: media.url), how: raw.how, title: '');
      case QueueHow.server:
        if (!_httpUrl(media.url)) throw const ProtocolException('relay fetch needs an http(s) url');
        if (!serverHasPassword) throw const ProtocolException('server fetch needs a server password');
        privateUrl = media.url;
        item = QueueItem(
            media: HelloMedia(name: name, size: 0, duration: 0, relay: const MediaRelay(fetch: true)),
            how: raw.how,
            title: '');
      case QueueHow.through:
      case QueueHow.file:
        if (!_key.hasMatch(raw.key)) throw const ProtocolException('a queued item of yours needs a key');
        item = QueueItem(
            media: HelloMedia(name: name, size: media.size < 0 ? 0 : media.size, duration: 0),
            how: raw.how,
            title: '',
            key: raw.key);
      case QueueHow.jellyfin:
        throw const ProtocolException('bad queue item');
    }
  }
  var title = cleanQueueText(sanitizeMediaName(raw.title));
  if (title.isEmpty) title = cleanQueueText(item.media.name.isEmpty ? 'media' : item.media.name);
  return (
    item: item.copyWith(
        title: title, sub: cleanQueueText(sanitizeMediaName(raw.sub)), duration: raw.duration),
    privateUrl: privateUrl,
  );
}

/// Applies one `queue` message from [token]; a refused add answers the
/// sender with `err` (the socket stays open).
void handleQueueIntent(ServerHub hub, String token, RelicWebSocket ws, Map<String, Object?> decoded) {
  final intent = QueueIntent.fromJson(decoded);
  final engine = hub.engine;
  var changed = false;
  switch (intent.op) {
    case 'add':
      final cleaned = cleanQueueAdd(intent.item!, serverHasPassword: hub.session.secret.isNotEmpty);
      final thumb = intent.thumb.isEmpty ? null : decodePicture(intent.thumb, RelayConstants.maxPosterBytes);
      final error = engine.applyQueueAdd(token, cleaned.item,
          next: intent.next, privateUrl: cleaned.privateUrl, thumb: thumb);
      if (error != null) {
        wsErr(ws, error);
        return;
      }
      changed = true;
    case 'move':
      changed = engine.applyQueueMove(token, intent.id, intent.to);
    case 'remove':
      changed = engine.applyQueueRemove(token, intent.id, why: intent.why);
    case 'play':
      changed = engine.applyQueuePlay(token, intent.id);
    case 'skip':
      changed = engine.applyQueuePlay(token, '');
  }
  if (changed) hub.changed();
}
