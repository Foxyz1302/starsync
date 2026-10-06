/// What the media picker selected. Null selection = nothing (hosting
/// without media is allowed).
sealed class PickedMedia {
  const PickedMedia();

  /// One line for summaries ("Playing: …").
  String get label;
}

/// A direct http(s) link everyone streams from.
final class LinkMedia extends PickedMedia {
  final String url;
  const LinkMedia(this.url);

  @override
  String get label {
    final uri = Uri.tryParse(url);
    final segs = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    if (segs.isEmpty) return uri?.host.isNotEmpty == true ? uri!.host : url;
    try {
      return Uri.decodeComponent(segs.last);
    } catch (_) {
      return segs.last;
    }
  }

  @override
  bool operator ==(Object other) => other is LinkMedia && other.url == url;
  @override
  int get hashCode => url.hashCode;
  @override
  String toString() => 'LinkMedia($url)';
}

/// A file on this computer; friends stream it from the host.
final class FileMedia extends PickedMedia {
  final String path;
  const FileMedia(this.path);

  @override
  String get label =>
      path.split(RegExp(r'[/\\]')).lastWhere((p) => p.isNotEmpty, orElse: () => path);

  @override
  bool operator ==(Object other) => other is FileMedia && other.path == path;
  @override
  int get hashCode => path.hashCode;
  @override
  String toString() => 'FileMedia($path)';
}

/// A movie or episode on a linked Jellyfin server. [serverId] keys the
/// account (`JellyfinAccounts.clientFor`); [baseUrl] is the address it was
/// picked through. No credentials in here: each side authorises its own.
final class JellyfinMedia extends PickedMedia {
  final String serverId;
  final String baseUrl;
  final String itemId;
  /// Null = the item's default source.
  final String? mediaSourceId;
  final String title;
  /// "Series · S1E6" for episodes, the year for movies; may be empty.
  final String subtitle;
  final Duration? runtime;
  const JellyfinMedia({
    required this.serverId,
    required this.baseUrl,
    required this.itemId,
    this.mediaSourceId,
    required this.title,
    this.subtitle = '',
    this.runtime,
  });

  @override
  String get label => subtitle.isEmpty ? title : '$title — $subtitle';

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'baseUrl': baseUrl,
        'itemId': itemId,
        'mediaSourceId': ?mediaSourceId,
        'title': title,
        'subtitle': subtitle,
        if (runtime != null) 'runtimeMs': runtime!.inMilliseconds,
      };

  static JellyfinMedia? fromJson(Object? j) {
    if (j is! Map) return null;
    final serverId = j['serverId'], baseUrl = j['baseUrl'], itemId = j['itemId'];
    if (serverId is! String || baseUrl is! String || itemId is! String) return null;
    final ms = j['runtimeMs'];
    return JellyfinMedia(
      serverId: serverId,
      baseUrl: baseUrl,
      itemId: itemId,
      mediaSourceId: j['mediaSourceId'] is String ? j['mediaSourceId'] as String : null,
      title: j['title'] is String ? j['title'] as String : '',
      subtitle: j['subtitle'] is String ? j['subtitle'] as String : '',
      runtime: ms is int ? Duration(milliseconds: ms) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JellyfinMedia &&
      other.serverId == serverId &&
      other.itemId == itemId &&
      other.mediaSourceId == mediaSourceId;
  @override
  int get hashCode => Object.hash(serverId, itemId, mediaSourceId);
  @override
  String toString() => 'JellyfinMedia($serverId/$itemId "$title")';
}
