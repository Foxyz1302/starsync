/// Server URL normalisation and Jellyfin link recognition.
library;

/// Normalises what a user typed as a server address into a base URL without
/// a trailing slash, e.g. `jelly.example.com/web/#/home` ->
/// `https://jelly.example.com`. A base path (reverse proxy sub-path such as
/// `https://example.com/jellyfin`) is kept. No scheme means https, except
/// for localhost and IP addresses, which get http. Returns null when the
/// input is not a usable http(s) URL.
String? normalizeServerUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) {
    final host = text.split(RegExp(r'[/:#?]')).first;
    final local = host == 'localhost' ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
        text.startsWith('[');
    text = '${local ? 'http' : 'https'}://$text';
  }
  final link = parseJellyfinLink(text);
  if (link != null) return link.baseUrl;
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    return null;
  }
  return _base(uri, _basePath(uri.pathSegments));
}

/// A Jellyfin item recognised in a pasted link. [serverId] is only known
/// when the link carried it (web UI links do); otherwise resolve it with
/// `JellyfinClient.publicInfo()` on [baseUrl].
class JellyfinLink {
  final String baseUrl;
  final String itemId;
  final String? serverId;
  const JellyfinLink({required this.baseUrl, required this.itemId, this.serverId});

  @override
  bool operator ==(Object other) =>
      other is JellyfinLink &&
      other.baseUrl == baseUrl &&
      other.itemId == itemId &&
      other.serverId == serverId;

  @override
  int get hashCode => Object.hash(baseUrl, itemId, serverId);

  @override
  String toString() => 'JellyfinLink($baseUrl, $itemId, serverId: $serverId)';
}

final _idPattern = RegExp(
    r'^([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$');

/// Jellyfin ids are GUIDs; the API prints them as 32 lowercase hex digits.
/// Returns that form, or null when [id] is not a GUID.
String? normalizeItemId(String id) {
  if (!_idPattern.hasMatch(id)) return null;
  return id.replaceAll('-', '').toLowerCase();
}

/// Recognises a Jellyfin item link and reduces it to (baseUrl, itemId):
/// - web UI: `/web/#/details?id=X&serverId=S`, `/web/index.html#!/details?id=X`,
///   any `#/...?id=X` route;
/// - API: `/Items/X/...`, `/Users/U/Items/X`, `/Videos/X/stream...`,
///   `/Audio/X/...`, `/UserItems/X/...`.
/// Returns null for anything else (including non-Jellyfin URLs, where it
/// cannot be sure).
JellyfinLink? parseJellyfinLink(String input) {
  final text = input.trim();
  if (!text.startsWith('http://') && !text.startsWith('https://')) return null;
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.host.isEmpty) return null;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  // Web UI: the route lives in the fragment, e.g. "/details?id=...".
  final webAt = segs.indexWhere((s) => s.toLowerCase() == 'web');
  if (webAt >= 0 && uri.fragment.isNotEmpty) {
    final frag = uri.fragment.replaceFirst(RegExp(r'^!'), '');
    final q = frag.indexOf('?');
    if (q >= 0) {
      final params = Uri.splitQueryString(frag.substring(q + 1));
      final id = normalizeItemId(params['id'] ?? '');
      if (id != null) {
        final sid = params['serverId'];
        return JellyfinLink(
          baseUrl: _base(uri, segs.sublist(0, webAt)),
          itemId: id,
          serverId: sid == null ? null : normalizeItemId(sid) ?? sid,
        );
      }
    }
  }

  // API paths: <base>/(Users/<u>/)?(Items|Videos|Audio|UserItems)/<id>/...
  for (var i = 0; i < segs.length - 1; i++) {
    final s = segs[i].toLowerCase();
    if (s != 'items' && s != 'videos' && s != 'audio' && s != 'useritems') continue;
    final id = normalizeItemId(segs[i + 1]);
    if (id == null) continue;
    var baseEnd = i;
    if (i >= 2 && segs[i - 2].toLowerCase() == 'users') baseEnd = i - 2;
    return JellyfinLink(baseUrl: _base(uri, segs.sublist(0, baseEnd)), itemId: id);
  }
  return null;
}

/// Path segments of the server base: everything before a `web` segment
/// (the web UI lives at `<base>/web/`), otherwise the whole path.
List<String> _basePath(List<String> segments) {
  final segs = segments.where((s) => s.isNotEmpty).toList();
  final webAt = segs.indexWhere((s) => s.toLowerCase() == 'web');
  return webAt >= 0 ? segs.sublist(0, webAt) : segs;
}

String _base(Uri uri, List<String> pathSegments) {
  final port = uri.hasPort ? ':${uri.port}' : '';
  final path = pathSegments.isEmpty
      ? ''
      : '/${pathSegments.map(Uri.encodeComponent).join('/')}';
  return '${uri.scheme}://${uri.host}$port$path';
}
