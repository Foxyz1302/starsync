import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home/media_picker.dart';
import '../state/connect_prefs.dart';
import 'motion.dart';

// The Library's Link source: a big paste field, a preview of what the link
// is, how the others get it (in a server), and the recent links.

const maxRecentLinks = 12;
const _keyRecentLinks = 'recentLinks';

/// A link put up before, newest first in [RecentLinks].
class RecentLink {
  final String url;
  final String title;
  final String? thumbnail;
  final DateTime at;
  const RecentLink({required this.url, required this.title, this.thumbnail, required this.at});

  Map<String, Object?> toJson() =>
      {'url': url, 'title': title, 'thumb': ?thumbnail, 'at': at.millisecondsSinceEpoch};

  static RecentLink? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = j['url'], title = j['title'], at = j['at'], thumb = j['thumb'];
    if (url is! String || url.isEmpty) return null;
    return RecentLink(
      url: url,
      title: title is String && title.isNotEmpty ? title : LinkMedia(url).label,
      thumbnail: thumb is String && thumb.isNotEmpty ? thumb : null,
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
    );
  }
}

/// [link] first, its older copy dropped, at most [maxRecentLinks].
List<RecentLink> pushRecentLink(List<RecentLink> list, RecentLink link) =>
    [link, ...list.where((l) => l.url != link.url)].take(maxRecentLinks).toList();

String encodeRecentLinks(List<RecentLink> list) => jsonEncode([for (final l in list) l.toJson()]);

List<RecentLink> decodeRecentLinks(Object? raw) {
  try {
    final j = raw is String ? jsonDecode(raw) : raw;
    if (j is! List) return const [];
    return [for (final e in j) ?RecentLink.fromJson(e)].take(maxRecentLinks).toList();
  } catch (_) {
    return const [];
  }
}

/// The recent links, kept in the `connect_form` box next to the last link.
class RecentLinks {
  static final RecentLinks instance = RecentLinks();

  RecentLinks({Future<Object?> Function()? read, Future<void> Function(String value)? write})
      : _read = read ?? _hiveRead,
        _write = write ?? _hiveWrite;

  final Future<Object?> Function() _read;
  final Future<void> Function(String value) _write;
  final links = ValueNotifier<List<RecentLink>>(const []);
  Future<void>? _load;

  static Future<Object?> _hiveRead() async =>
      (connectFormBoxIfOpen() ?? await openConnectFormBox()).get(_keyRecentLinks);

  static Future<void> _hiveWrite(String value) async =>
      (connectFormBoxIfOpen() ?? await openConnectFormBox()).put(_keyRecentLinks, value);

  Future<void> ensureLoaded() => _load ??= () async {
        try {
          final read = decodeRecentLinks(await _read());
          // Something added meanwhile stays on top.
          var all = read;
          for (final l in links.value.reversed) {
            all = pushRecentLink(all, l);
          }
          links.value = all;
        } catch (e) {
          debugPrint('load recent links failed: $e');
        }
      }();

  Future<void> add(RecentLink link) async {
    links.value = pushRecentLink(links.value, link);
    try {
      await _write(encodeRecentLinks(links.value));
    } catch (e) {
      debugPrint('save recent links failed: $e');
    }
  }
}

// ------------------------------------------------------------- preview

/// What a pasted link is, for the preview card and the recent list.
class LinkPreview {
  final String title;
  /// "youtube.com · Channel", or the host.
  final String subtitle;
  final String? thumbnail;
  const LinkPreview({required this.title, required this.subtitle, this.thumbnail});
}

/// GET [uri] and return the body (oEmbed).
typedef OEmbedGetter = Future<String> Function(Uri uri);

Future<String> defaultOEmbedGet(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw HttpException('status ${res.statusCode}', uri: uri);
    return await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
  } finally {
    client.close(force: true);
  }
}

bool isYouTubeLink(Uri uri) {
  final h = uri.host.toLowerCase();
  return h == 'youtu.be' || h == 'youtube.com' || h.endsWith('.youtube.com');
}

String _host(Uri uri) => uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;

/// The preview of [url]: YouTube links ask YouTube's oEmbed for the title,
/// channel and thumbnail; anything else (or a failed lookup) shows the
/// file name and host. Null for text that is not an http(s) link.
Future<LinkPreview?> previewLink(String url, {OEmbedGetter get = defaultOEmbedGet}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  final plain = LinkPreview(title: LinkMedia(url.trim()).label, subtitle: _host(uri));
  if (!isYouTubeLink(uri)) return plain;
  try {
    final body = await get(Uri.https('www.youtube.com', '/oembed', {'url': url.trim(), 'format': 'json'}));
    final j = jsonDecode(body);
    if (j is! Map || j['title'] is! String) return plain;
    final author = j['author_name'];
    return LinkPreview(
      title: j['title'] as String,
      subtitle: [_host(uri), if (author is String && author.isNotEmpty) author].join(' · '),
      thumbnail: j['thumbnail_url'] is String ? j['thumbnail_url'] as String : null,
    );
  } catch (_) {
    return plain;
  }
}

/// "today", "yesterday", "3 days ago", "last week", "5 weeks ago", ...
String agoText(DateTime at, DateTime now) {
  final d = now.difference(at).inDays;
  if (d < 1) return 'today';
  if (d < 2) return 'yesterday';
  if (d < 7) return '$d days ago';
  if (d < 14) return 'last week';
  if (d < 60) return '${d ~/ 7} weeks ago';
  if (d < 365) return '${d ~/ 30} months ago';
  return 'over a year ago';
}

// -------------------------------------------------------------- widget

const _modes = [
  (LinkRelay.direct, Icons.groups_outlined, 'Everyone fetches it', 'Each app plays the link itself.'),
  (
    LinkRelay.server,
    Icons.dns_outlined,
    'Server fetches it',
    'Downloaded once by the server. For links slow or blocked for some.'
  ),
  (LinkRelay.me, Icons.cell_tower, 'Through me', 'Your computer passes it on. For links only you can open.'),
];

String linkRelayHelp(LinkRelay r) => switch (r) {
      LinkRelay.direct => 'Everyone streams the link themselves. Jellyfin links are shared as the item, '
          'without your sign-in.',
      LinkRelay.server => 'The server downloads it once and streams it to everyone. It must be able to '
          'reach the link; the link is not shown to anyone.',
      LinkRelay.me => 'This computer downloads it and passes it on through the server. Keep the app open '
          'while it plays; the link is not shown to anyone.',
    };

/// The Link source. [offlineHint] set: the button is off and says why.
class LibraryLinkSource extends StatefulWidget {
  final MediaPickerController controller;
  final String? offlineHint;
  /// Puts the link up; returns an error text, or null when sent.
  final Future<String?> Function(LinkMedia media) onPutUp;
  final RecentLinks recents;
  final OEmbedGetter oembed;
  const LibraryLinkSource({
    super.key,
    required this.controller,
    required this.onPutUp,
    required this.recents,
    this.offlineHint,
    this.oembed = defaultOEmbedGet,
  });

  @override
  State<LibraryLinkSource> createState() => _LibraryLinkSourceState();
}

class _LibraryLinkSourceState extends State<LibraryLinkSource> {
  MediaPickerController get _c => widget.controller;
  final _previews = <String, LinkPreview?>{};
  String _previewUrl = '';
  Timer? _debounce;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.recents.ensureLoaded();
    _c.link.addListener(_typed);
    _typed();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c.link.removeListener(_typed);
    super.dispose();
  }

  void _typed() {
    final url = _c.link.text.trim();
    if (url == _previewUrl) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _preview(url));
    if (mounted) setState(() => _error = null);
  }

  Future<void> _preview(String url) async {
    _previewUrl = url;
    if (url.isEmpty || _previews.containsKey(url)) {
      if (mounted) setState(() {});
      return;
    }
    final p = await previewLink(url, get: widget.oembed);
    _previews[url] = p;
    if (mounted) setState(() {});
  }

  Future<void> _paste() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      if (text != null && text.isNotEmpty) _c.link.text = text;
    } catch (_) {}
  }

  Future<void> _go() async {
    final url = _c.link.text.trim();
    if (url.isEmpty || _busy || widget.offlineHint != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onPutUp(LinkMedia(url, relay: _c.linkRelay));
    } catch (e) {
      error = '$e';
    }
    if (error == null) {
      final p = _previews[url] ?? await previewLink(url, get: widget.oembed);
      unawaited(widget.recents.add(RecentLink(
        url: url,
        title: p?.title ?? LinkMedia(url).label,
        thumbnail: p?.thumbnail,
        at: DateTime.now(),
      )));
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final hint = widget.offlineHint;
    final url = _c.link.text.trim();
    final preview = url.isEmpty ? null : _previews[url];
    final loading = url.isNotEmpty && !_previews.containsKey(url);
    final field = TextField(
      key: const ValueKey('link-field'),
      controller: _c.link,
      style: const TextStyle(fontSize: 16),
      keyboardType: TextInputType.url,
      onSubmitted: (_) => _go(),
      decoration: InputDecoration(
        hintText: 'https://…',
        prefixIcon: const Icon(Icons.link),
        suffixIcon: IconButton(onPressed: _paste, tooltip: 'Paste', icon: const Icon(Icons.content_paste)),
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      ),
    );
    final button = FilledButton.icon(
      key: const ValueKey('link-put-up'),
      onPressed: url.isEmpty || _busy || hint != null ? null : _go,
      icon: _busy
          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.play_arrow),
      label: Text(hint == null ? 'Put it up' : 'Play'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return SingleChildScrollView(
      key: const ValueKey('media-link'),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(Icons.link, size: 32, color: scheme.primary),
                ),
              ),
              const SizedBox(height: 14),
              Text('Watch from a link', textAlign: TextAlign.center, style: t.headlineSmall),
              const SizedBox(height: 6),
              Text(
                'A video file, YouTube, a Jellyfin link… Ctrl+V anywhere pastes it here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              LayoutBuilder(
                builder: (context, box) => box.maxWidth < 460
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        field,
                        const SizedBox(height: 10),
                        button,
                      ])
                    : Row(children: [Expanded(child: field), const SizedBox(width: 12), button]),
              ),
              if (hint != null || _error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error ?? hint!,
                  key: const ValueKey('link-hint'),
                  textAlign: TextAlign.center,
                  style: t.bodySmall?.copyWith(color: _error != null ? scheme.error : Colors.grey),
                ),
              ],
              AnimatedSize(
                duration: easeTime,
                curve: ease,
                child: url.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: _PreviewCard(preview: preview, loading: loading),
                      ),
              ),
              if (hint == null) ...[
                const SizedBox(height: 28),
                Text('How the others get it', style: t.titleSmall),
                const SizedBox(height: 10),
                LayoutBuilder(builder: (context, box) {
                  final cards = [
                    for (final m in _modes)
                      _ModeCard(
                        key: ValueKey('link-mode-${m.$1.name}'),
                        icon: m.$2,
                        title: m.$3,
                        sub: m.$4,
                        selected: _c.linkRelay == m.$1,
                        onTap: () => setState(() => _c.linkRelay = m.$1),
                      ),
                  ];
                  if (box.maxWidth < 560) {
                    return Column(children: [
                      for (final (i, c) in cards.indexed) ...[if (i > 0) const SizedBox(height: 8), c],
                    ]);
                  }
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, c) in cards.indexed) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(child: c),
                        ],
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 8),
                Text(linkRelayHelp(_c.linkRelay), style: t.bodySmall?.copyWith(color: Colors.grey)),
              ],
              ValueListenableBuilder<List<RecentLink>>(
                valueListenable: widget.recents.links,
                builder: (context, recents, _) => recents.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 32),
                        child: _RecentGrid(recents: recents, onPick: (l) => _c.link.text = l.url),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final LinkPreview? preview;
  final bool loading;
  const _PreviewCard({required this.preview, required this.loading});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = preview;
    return Container(
      key: const ValueKey('link-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 160, height: 90, child: _Thumb(url: p?.thumbnail)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: loading
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p?.title ?? 'Not a link',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p?.subtitle ?? 'Paste an http(s) address',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String? url;
  const _Thumb({required this.url});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.movie_outlined, color: Colors.grey)),
    );
    final u = url;
    if (u == null) return fallback;
    return Image.network(u, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final bool selected;
  final VoidCallback onTap;
  const _ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: easeTime,
          curve: ease,
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.10) : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: selected ? scheme.primary : null)),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentGrid extends StatelessWidget {
  final List<RecentLink> recents;
  final ValueChanged<RecentLink> onPick;
  const _RecentGrid({required this.recents, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Recent', style: t.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, box) {
          const gap = 12.0;
          final cols = box.maxWidth > 600 ? 3 : 2;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final l in recents)
                SizedBox(
                  width: w,
                  child: Tooltip(
                    message: l.url,
                    waitDuration: const Duration(milliseconds: 600),
                    child: InkWell(
                      key: ValueKey('recent-link-${l.url}'),
                      onTap: () => onPick(l),
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 16 / 9,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _Thumb(url: l.thumbnail),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(l.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            [_host(Uri.tryParse(l.url) ?? Uri()), agoText(l.at, now)]
                                .where((s) => s.isNotEmpty)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        }),
      ],
    );
  }
}
