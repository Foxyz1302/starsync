import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';
import 'protocol.dart';
import 'sync_engine.dart';
import 'whats_next.dart';

// Up next: what plays after the current media, held by the server for
// everyone (see PROTOCOL.md "Queue"). Wire types, and [EngineQueue], the
// server's list (pure, so the engine and tests share it).

/// How a queued item plays, and so who can put it up when it comes up.
enum QueueHow {
  /// A link everyone opens themselves: anyone puts it up.
  direct,
  /// A link the server fetches: anyone puts it up (the server keeps the URL).
  server,
  /// A link the adder's app reads and passes on: only the adder.
  through,
  /// A file on the adder's computer: only the adder.
  file,
  /// A Jellyfin item: someone with an account on that server.
  jellyfin;

  static QueueHow? parse(Object? v) {
    for (final h in values) {
      if (h.name == v) return h;
    }
    return null;
  }

  /// Only the adder's app has what it needs (its file, its cookies).
  bool get adderOnly => this == through || this == file;
}

/// One entry of Up next as everyone sees it. [media] is what the swap
/// puts up, without a URL for [QueueHow.server], [QueueHow.through] and
/// [QueueHow.file] (the server, or the adder's app, keeps it). [key]: the
/// adder's own handle for what it keeps (adder-only items). [auto]: the
/// continuation of media [forMedia] (the next episode): at most one, always
/// after the others, replaced by a newer one, dropped by any swap that does
/// not put it up (wire `auto` and `for`).
class QueueItem {
  final String id;
  final HelloMedia media;
  final QueueHow how;
  final String title;
  /// A second line: the site, uploader or show; may be empty.
  final String sub;
  /// Seconds, 0 when unknown.
  final double duration;
  /// Picture hash, served at `/i/...`; empty when none.
  final String thumb;
  /// Member id and name of who added it (the name as it was then).
  final String by;
  final String byName;
  final String key;
  final bool auto;
  /// The `mediaId` an [auto] item continues; 0 otherwise.
  final int forMedia;
  const QueueItem({
    this.id = '',
    required this.media,
    required this.how,
    required this.title,
    this.sub = '',
    this.duration = 0,
    this.thumb = '',
    this.by = '',
    this.byName = '',
    this.key = '',
    this.auto = false,
    this.forMedia = 0,
  });

  QueueItem copyWith({String? id, HelloMedia? media, String? title, String? sub, double? duration,
          String? thumb, String? by, String? byName, String? key, bool? auto, int? forMedia}) =>
      QueueItem(
        id: id ?? this.id,
        media: media ?? this.media,
        how: how,
        title: title ?? this.title,
        sub: sub ?? this.sub,
        duration: duration ?? this.duration,
        thumb: thumb ?? this.thumb,
        by: by ?? this.by,
        byName: byName ?? this.byName,
        key: key ?? this.key,
        auto: auto ?? this.auto,
        forMedia: forMedia ?? this.forMedia,
      );

  Map<String, Object?> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'media': media.toJson(),
        'how': how.name,
        'title': title,
        if (sub.isNotEmpty) 'sub': sub,
        if (duration > 0) 'duration': duration,
        if (thumb.isNotEmpty) 'thumb': thumb,
        if (by.isNotEmpty) 'by': by,
        if (byName.isNotEmpty) 'byName': byName,
        if (key.isNotEmpty) 'key': key,
        if (auto) 'auto': true,
        if (auto) 'for': forMedia,
      };

  /// Null when [j] is not an item this side can read.
  static QueueItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final media = j['media'];
    final how = QueueHow.parse(j['how']);
    if (media is! Map || how == null) return null;
    final d = j['duration'];
    return QueueItem(
      id: j['id'] is String ? j['id'] as String : '',
      media: HelloMedia.fromJson(Map<String, Object?>.from(media)),
      how: how,
      title: j['title'] is String ? j['title'] as String : '',
      sub: j['sub'] is String ? j['sub'] as String : '',
      duration: d is num && d.isFinite && d > 0 ? d.toDouble() : 0,
      thumb: j['thumb'] is String ? j['thumb'] as String : '',
      by: j['by'] is String ? j['by'] as String : '',
      byName: j['byName'] is String ? j['byName'] as String : '',
      key: j['key'] is String ? j['key'] as String : '',
      auto: j['auto'] == true,
      forMedia: j['auto'] == true && j['for'] is num && (j['for'] as num).isFinite ? (j['for'] as num).toInt() : 0,
    );
  }
}

/// Client to server: one change to Up next. [op] `add` (with [item],
/// [next] = right after what plays instead of at the end, [thumb] base64
/// picture), `move` ([id] to index [to]), `remove` ([id]; [why] set when it
/// is skipped because it cannot play), `play` ([id] now), `skip` (the
/// first item now) or `cancel` (drops the [QueueItem.auto] item and the
/// countdown, `state.advance`, for everyone).
class QueueIntent {
  final String op;
  final QueueItem? item;
  final bool next;
  final String thumb;
  final String id;
  final int to;
  final String why;
  const QueueIntent._(this.op,
      {this.item, this.next = false, this.thumb = '', this.id = '', this.to = 0, this.why = ''});

  const QueueIntent.add(QueueItem item, {bool next = false, String thumb = ''})
      : this._('add', item: item, next: next, thumb: thumb);
  const QueueIntent.move(String id, int to) : this._('move', id: id, to: to);
  const QueueIntent.remove(String id, {String why = ''}) : this._('remove', id: id, why: why);
  const QueueIntent.play(String id) : this._('play', id: id);
  const QueueIntent.skip() : this._('skip');
  const QueueIntent.cancel() : this._('cancel');

  static const ops = {'add', 'move', 'remove', 'play', 'skip', 'cancel'};

  Map<String, Object?> toJson() => {
        't': 'queue',
        'op': op,
        if (item != null) 'item': item!.toJson(),
        if (op == 'add') 'at': next ? 'next' : 'end',
        if (thumb.isNotEmpty) 'thumb': thumb,
        if (id.isNotEmpty) 'id': id,
        if (op == 'move') 'to': to,
        if (why.isNotEmpty) 'why': why,
      };

  factory QueueIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'queue') throw const ProtocolException('not a queue intent');
    final op = json['op'];
    if (op is! String || !ops.contains(op)) throw const ProtocolException('unknown queue op');
    final item = QueueItem.fromJson(json['item']);
    if (op == 'add' && item == null) throw const ProtocolException('queue add needs an item');
    return QueueIntent._(op,
        item: item,
        next: json['at'] == 'next',
        thumb: json['thumb'] is String ? json['thumb'] as String : '',
        id: json['id'] is String ? json['id'] as String : '',
        to: finiteInt(json['to'], 'to'),
        why: json['why'] is String ? _cut(json['why'] as String, 120) : '');
  }
}

String _cut(String s, int max) {
  final line = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length > max ? line.substring(0, max) : line;
}

/// Display text of a queued item: one line, at most
/// [RelayConstants.maxQueueTextLength] characters.
String cleanQueueText(String s) => _cut(s, RelayConstants.maxQueueTextLength);

class _Entry {
  QueueItem item;
  /// A server-fetched link's URL: never broadcast.
  final String? privateUrl;
  final ({String hash, Uint8List bytes})? thumb;
  _Entry(this.item, this.privateUrl, this.thumb);
}

/// The server's Up next: items in order with server-assigned ids, and at
/// most one pending [play] request (an item someone asked to play now,
/// waiting for the member who can put it up). In memory only.
class EngineQueue {
  final List<_Entry> _items = [];
  int _nextId = 1;
  String? play;
  DateTime? _playAt;

  List<QueueItem> get items => [for (final e in _items) e.item];
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  int _index(String id) => _items.indexWhere((e) => e.item.id == id);
  bool has(String id) => _index(id) >= 0;
  QueueItem? item(String id) {
    final i = _index(id);
    return i < 0 ? null : _items[i].item;
  }

  /// The URL a server-fetched item keeps to itself.
  String? privateUrlOf(String id) {
    final i = _index(id);
    return i < 0 ? null : _items[i].privateUrl;
  }

  /// The continuation item ([QueueItem.auto]), always last; null when none.
  QueueItem? get auto {
    final i = _autoIndex;
    return i < 0 ? null : _items[i].item;
  }

  int get _autoIndex => _items.indexWhere((e) => e.item.auto);

  /// Adds [item] (already cleaned) with a fresh id, at the end (before the
  /// [auto] item) or, with [next], first. An [QueueItem.auto] item goes
  /// last and replaces the earlier one. Null when full
  /// ([RelayConstants.maxQueueItems]).
  QueueItem? add(QueueItem item, {bool next = false, String? privateUrl, Uint8List? thumb}) {
    if (item.auto) dropAuto();
    if (_items.length >= RelayConstants.maxQueueItems) return null;
    final t = thumb == null ? null : ArtImage(thumb);
    final added = item.copyWith(id: 'q${_nextId++}', thumb: t?.hash ?? '');
    final e = _Entry(added, privateUrl, t == null ? null : (hash: t.hash, bytes: t.bytes));
    if (item.auto) {
      _items.add(e);
    } else if (next) {
      _items.insert(0, e);
    } else {
      final a = _autoIndex;
      _items.insert(a < 0 ? _items.length : a, e);
    }
    return added;
  }

  /// Drops the [auto] item; returns it (null when there was none).
  QueueItem? dropAuto() {
    final i = _autoIndex;
    if (i < 0) return null;
    final a = _items.removeAt(i).item;
    if (play == a.id) _clearPlay();
    return a;
  }

  /// Moves [id] to [to] (clamped). False when unknown or unchanged.
  bool move(String id, int to) {
    final i = _index(id);
    if (i < 0) return false;
    // The auto item stays after the others: it does not move, nothing
    // moves past it.
    final a = _autoIndex;
    if (i == a) return false;
    final last = _items.length - (a < 0 ? 1 : 2);
    final target = to.clamp(0, last);
    if (target == i) return false;
    final e = _items.removeAt(i);
    _items.insert(target, e);
    return true;
  }

  /// Removes [id]; returns it, or null when unknown.
  QueueItem? remove(String id) {
    final i = _index(id);
    if (i < 0) return null;
    final e = _items.removeAt(i);
    if (play == id) _clearPlay();
    return e.item;
  }

  /// Someone asked to play [id] now: it moves first and waits for the
  /// member who can put it up ([play]). False when unknown.
  bool requestPlay(String id, DateTime now) {
    final i = _index(id);
    if (i < 0) return false;
    if (i > 0) _items.insert(0, _items.removeAt(i));
    play = id;
    _playAt = now;
    return true;
  }

  /// A swap happened: [id] (when it came from Up next) leaves the list,
  /// the [auto] item goes too unless it is [id], and any pending play
  /// request is over.
  void swapped(String? id) {
    if (auto?.id != id) dropAuto();
    if (id != null) {
      final i = _index(id);
      if (i >= 0) _items.removeAt(i);
    }
    _clearPlay();
  }

  /// A play request nobody acted on ends after
  /// [RelayConstants.queuePlayTimeoutSecs]. Returns whether it changed.
  bool tick(DateTime now) {
    final at = _playAt;
    if (play == null || at == null) return false;
    if (now.difference(at).inSeconds < RelayConstants.queuePlayTimeoutSecs) return false;
    _clearPlay();
    return true;
  }

  void _clearPlay() {
    play = null;
    _playAt = null;
  }

  /// Bytes of an item's picture by hash.
  Uint8List? thumbFor(String hash) {
    for (final e in _items) {
      if (e.thumb?.hash == hash) return e.thumb!.bytes;
    }
    return null;
  }
}

/// Why a `queue` message was refused: the `err` the sender gets.
typedef QueueRefusal = ({ErrCode code, String message});

/// The `queue` messages applied to the engine's [SyncEngine.queue], with
/// their feed lines (`queue-add`, `queue-remove`, `queue-skip`,
/// `advance-cancel`), then what's next ([SyncEngine.whatsNext]). Each
/// returns whether the queue changed; [applyQueueAdd] a refusal for the
/// sender instead (null when added).
extension EngineQueueOps on SyncEngine {
  /// [item] is already cleaned by the server (see `cleanQueueAdd`). An
  /// [QueueItem.auto] item must continue the current media
  /// ([QueueItem.forMedia] = [SyncEngine.mediaId]) and come from who put
  /// it up or, when that member is not `in`, from the first member who is
  /// ([mayAddContinuation]); it adds no feed line (it is no news).
  QueueRefusal? applyQueueAdd(String token, QueueItem item,
      {bool next = false, String? privateUrl, Uint8List? thumb}) {
    final member = members[token];
    if (member == null) return null;
    if (item.auto) {
      if (media == null || item.forMedia != mediaId) {
        return (code: ErrCode.bad, message: 'bad message: an auto item must name the current media');
      }
      final views = [for (final m in members.values) m.view(inGate: false)];
      if (!mayAddContinuation(member.id, members[swapBy]?.id, views)) {
        return (code: ErrCode.forbidden, message: 'only who put this media up adds what continues it');
      }
    }
    final added = queue.add(item.copyWith(by: member.id, byName: member.name),
        next: next, privateUrl: privateUrl, thumb: thumb);
    if (added == null) return (code: ErrCode.full, message: 'Up next is full (${RelayConstants.maxQueueItems} items)');
    if (!added.auto) {
      feed.add(FeedMessage(
          actor: member.name, actorId: member.id, action: 'queue-add', target: added.title, at: now));
    }
    whatsNext();
    return null;
  }

  bool applyQueueMove(String token, String id, int to) {
    if (!members.containsKey(token) || !queue.move(id, to)) return false;
    whatsNext();
    return true;
  }

  /// [why] set: skipped because it cannot play (`queue-skip`, with the
  /// reason), else removed by hand (`queue-remove`).
  bool applyQueueRemove(String token, String id, {String why = ''}) {
    final member = members[token];
    if (member == null) return false;
    final gone = queue.remove(id);
    if (gone == null) return false;
    feed.add(FeedMessage(
        actor: member.name,
        actorId: member.id,
        action: why.isEmpty ? 'queue-remove' : 'queue-skip',
        target: gone.title,
        reason: why,
        at: now));
    whatsNext();
    return true;
  }

  /// `play` ([id]) or `skip` (the first item, [id] empty).
  bool applyQueuePlay(String token, String id) {
    if (!members.containsKey(token)) return false;
    final target = id.isEmpty ? (queue.isEmpty ? null : queue.items.first.id) : id;
    if (target == null || queue.play == target) return false;
    if (!queue.requestPlay(target, now)) return false;
    whatsNext();
    return true;
  }

  /// `cancel`: drops the continuation ([EngineQueue.auto]) and the
  /// countdown ([SyncEngine.advance]) for everyone (feed `advance-cancel`);
  /// no countdown starts again for this media.
  bool applyQueueCancel(String token) {
    final member = members[token];
    if (member == null) return false;
    final dropped = queue.dropAuto();
    final hadAdvance = advance != null;
    cancelAdvance();
    if (dropped == null && !hadAdvance) return false;
    feed.add(FeedMessage(
        actor: member.name, actorId: member.id, action: 'advance-cancel', target: dropped?.title, at: now));
    return true;
  }
}
