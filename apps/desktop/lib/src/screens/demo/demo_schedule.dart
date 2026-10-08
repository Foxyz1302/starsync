part of 'shell_demo.dart';

// DEBUG ONLY: the Schedule tab on real data.
// - AniList airingSchedules (public, no login): every episode airing from
//   last week's Monday to four weeks out, exact times, covers, banners.
// - AnimeFlow (https://anime.example.org/api/app/v1, authenticated with
//   the linked Example Jellyfin account's own token): status per episode,
//   matched by the episode's AniList id + episode number, else by AniList
//   id + air day. Read-only: requests are simulated, nothing is sent.

const _animeFlowBase = 'https://anime.example.org/api/app/v1';

enum _EpStatus {
  available,
  downloading,
  upcoming,
  missing,
  failed,
  unmonitored,
  notTracked,
}

class _Airing {
  final int anilistId;
  final String title;
  final int episode;
  final DateTime at; // local
  final String? cover, banner;
  final Color tint;
  final int popularity;
  _EpStatus status;
  double? progress;
  String? reason;
  bool followed = false;
  bool tracked = false;
  _Airing({
    required this.anilistId,
    required this.title,
    required this.episode,
    required this.at,
    this.cover,
    this.banner,
    required this.tint,
    required this.popularity,
    required this.status,
  });
}

class _Req {
  final String who;
  final String what;
  String status;
  final String? reason;
  _Req(this.who, this.what, this.status, [this.reason]);
}

final _requests = ValueNotifier<List<_Req>>([]);

Color _hex(String? s, Color fallback) {
  if (s == null || !s.startsWith('#') || s.length != 7) return fallback;
  return Color(int.parse('ff${s.substring(1)}', radix: 16));
}

Future<Object?> _getJson(
  HttpClient http,
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  final req = await http.getUrl(url).timeout(const Duration(seconds: 15));
  headers.forEach(req.headers.set);
  final res = await req.close().timeout(const Duration(seconds: 20));
  final body = await res.transform(const Utf8Decoder()).join();
  if (res.statusCode != 200) {
    throw HttpException(
      'HTTP ${res.statusCode} ${body.length > 120 ? body.substring(0, 120) : body}',
      uri: url,
    );
  }
  return jsonDecode(body);
}

/// AniList: all airings in [from, to), paged (50 per page; AniList allows
/// 90 requests/min).
/// AniList: all airings in [from, to), paged (50 per page). AniList's
/// limit is per minute, so the raw pages are cached: in memory for 10 min
/// (tab switches), on disk for an hour (restarts). A 429 waits out
/// Retry-After once; if AniList still refuses, stale cached data is used.
class _AniListCache {
  final DateTime fetched;
  final int from;
  final List<Map> raw;
  const _AniListCache(this.fetched, this.from, this.raw);
}

_AniListCache? _aniMem;

File get _aniDisk =>
    File('${Directory.systemTemp.path}/wt-demo-anilist-schedule.json');

Future<_AniListCache?> _aniFromDisk(int from) async {
  try {
    final j = jsonDecode(await _aniDisk.readAsString()) as Map;
    if (j['from'] != from) return null;
    return _AniListCache(
      DateTime.fromMillisecondsSinceEpoch(j['fetched'] as int),
      from,
      (j['raw'] as List).cast<Map>(),
    );
  } catch (_) {
    return null;
  }
}

/// The raw airings, and when they were fetched if AniList refused and
/// older cached data is returned instead.
Future<(List<Map>, DateTime?)> _anilistRaw(
  HttpClient http,
  DateTime from,
  DateTime to,
) async {
  final key = from.millisecondsSinceEpoch ~/ 1000;
  final mem = _aniMem;
  if (mem != null &&
      mem.from == key &&
      DateTime.now().difference(mem.fetched) < const Duration(minutes: 10)) {
    return (mem.raw, null);
  }
  final disk = await _aniFromDisk(key);
  if (disk != null &&
      DateTime.now().difference(disk.fetched) < const Duration(hours: 1)) {
    _aniMem = disk;
    return (disk.raw, null);
  }
  try {
    final raw = await _anilistFetch(http, from, to);
    final c = _aniMem = _AniListCache(DateTime.now(), key, raw);
    unawaited(
      _aniDisk
          .writeAsString(
            jsonEncode({
              'fetched': c.fetched.millisecondsSinceEpoch,
              'from': key,
              'raw': raw,
            }),
          )
          .then((_) {}, onError: (_) {}),
    );
    return (raw, null);
  } catch (e) {
    final stale = mem?.from == key ? mem : disk;
    if (stale != null) return (stale.raw, stale.fetched);
    rethrow;
  }
}

Future<List<Map>> _anilistFetch(
  HttpClient http,
  DateTime from,
  DateTime to,
) async {
  const query = r"""
query($from:Int,$to:Int,$page:Int){Page(page:$page,perPage:50){pageInfo{hasNextPage}
airingSchedules(airingAt_greater:$from,airingAt_lesser:$to,sort:TIME){airingAt episode
media{id title{romaji english} coverImage{large color} bannerImage isAdult popularity format}}}}""";
  final out = <Map>[];
  for (var page = 1; page <= 20; page++) {
    Map? data;
    for (var attempt = 0; attempt < 2 && data == null; attempt++) {
      final req = await http
          .postUrl(Uri.parse('https://graphql.anilist.co'))
          .timeout(const Duration(seconds: 15));
      req.headers
        ..contentType = ContentType.json
        ..set('Accept', 'application/json');
      req.write(
        jsonEncode({
          'query': query,
          'variables': {
            'from': from.millisecondsSinceEpoch ~/ 1000,
            'to': to.millisecondsSinceEpoch ~/ 1000,
            'page': page,
          },
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(const Utf8Decoder()).join();
      if (res.statusCode == 429 && attempt == 0) {
        final wait = int.tryParse(res.headers.value('retry-after') ?? '') ?? 30;
        await Future<void>.delayed(Duration(seconds: wait.clamp(1, 65)));
        continue;
      }
      if (res.statusCode != 200) {
        throw HttpException('AniList HTTP ${res.statusCode}');
      }
      data = (jsonDecode(body) as Map)['data']['Page'] as Map;
    }
    if (data == null) throw const HttpException('AniList HTTP 429');
    out.addAll((data['airingSchedules'] as List).cast<Map>());
    if ((data['pageInfo'] as Map)['hasNextPage'] != true) break;
  }
  return out;
}

/// Fresh [_Airing]s from raw AniList entries (the overlay mutates them).
List<_Airing> _airingsFrom(List<Map> raw) {
  final out = <_Airing>[];
  for (final a in raw) {
    final m = a['media'] as Map;
    if (m['isAdult'] == true || m['format'] == 'MUSIC') continue;
    final t = m['title'] as Map;
    final at = DateTime.fromMillisecondsSinceEpoch(
      (a['airingAt'] as int) * 1000,
    );
    out.add(
      _Airing(
        anilistId: m['id'] as int,
        title: (t['english'] as String?) ?? (t['romaji'] as String?) ?? '?',
        episode: a['episode'] as int,
        at: at,
        cover: (m['coverImage'] as Map?)?['large'] as String?,
        banner: m['bannerImage'] as String?,
        tint: _hex(
          (m['coverImage'] as Map?)?['color'] as String?,
          Colors.blueGrey,
        ),
        popularity: (m['popularity'] as int?) ?? 0,
        status: at.isAfter(DateTime.now())
            ? _EpStatus.upcoming
            : _EpStatus.notTracked,
      ),
    );
  }
  return out;
}

class _FlowState {
  final String? user;
  final List<String> scopes;
  final String? error;
  const _FlowState({this.user, this.scopes = const [], this.error});
}

/// The linked Jellyfin account on example.org (AnimeFlow accepts its
/// token), or null.
Future<String?> _exampleToken() async {
  final acc = JellyfinAccounts.instance;
  await acc.ensureLoaded(validate: false);
  for (final a in acc.accounts) {
    if (a.urls.any((u) => u.contains('example.org'))) return a.token;
  }
  return null;
}

String _utc(DateTime d) => '${d.toUtc().toIso8601String().split('.').first}Z';

/// Overlays AnimeFlow's statuses onto [items]; returns who we are there.
Future<_FlowState> _overlayAnimeFlow(
  HttpClient http,
  List<_Airing> items,
  DateTime from,
  DateTime to,
) async {
  final token = await _exampleToken();
  if (token == null) {
    return const _FlowState(
      error: 'Link the Example Jellyfin server to see AnimeFlow statuses',
    );
  }
  final h = {'X-Emby-Token': token};
  final me =
      await _getJson(http, Uri.parse('$_animeFlowBase/me'), headers: h) as Map;
  final sched = await _getJson(
    http,
    Uri.parse('$_animeFlowBase/schedule')
        .replace(queryParameters: {'from': _utc(from), 'to': _utc(to)}),
    headers: h,
  ) as Map;
  final series = await _getJson(
    http,
    Uri.parse('$_animeFlowBase/series'),
    headers: h,
  ) as Map;
  final tracked = <int>{};
  final followed = <int>{};
  for (final s in (series['items'] as List).cast<Map>()) {
    final id = s['anilist_id'];
    if (id is int) {
      tracked.add(id);
      if (s['followed'] == true) followed.add(id);
    }
  }
  final byEp = <String, Map>{};
  final byDay = <String, Map>{};
  for (final e in (sched['items'] as List).cast<Map>()) {
    final id = e['anilist_id'];
    if (id is! int) continue;
    tracked.add(id);
    if (e['followed'] == true) followed.add(id);
    byEp['$id#${e['episode']}'] = e;
    final air = e['air_date'] is String
        ? DateTime.tryParse(e['air_date'] as String)?.toLocal()
        : null;
    if (air != null) byDay['$id#${air.year}-${air.month}-${air.day}'] = e;
  }
  for (final a in items) {
    a.tracked = tracked.contains(a.anilistId);
    a.followed = followed.contains(a.anilistId);
    final e =
        byEp['${a.anilistId}#${a.episode}'] ??
        byDay['${a.anilistId}#${a.at.year}-${a.at.month}-${a.at.day}'];
    if (e != null) {
      a.status = switch (e['status']) {
        'available' => _EpStatus.available,
        'downloading' => _EpStatus.downloading,
        'missing' => _EpStatus.missing,
        'failed' => _EpStatus.failed,
        'unmonitored' => _EpStatus.unmonitored,
        _ => _EpStatus.upcoming,
      };
      a.progress = (e['progress'] as num?)?.toDouble();
      a.reason = e['reason'] as String?;
    } else if (a.tracked && a.at.isBefore(DateTime.now())) {
      a.status =
          _EpStatus.missing; // tracked and aired, AnimeFlow has nothing for it
    }
  }
  final scopes = ((me['scopes'] as List?) ?? const []).cast<String>();
  // Requests, read-only.
  try {
    final reqs = await _getJson(
      http,
      Uri.parse('$_animeFlowBase/requests').replace(
        queryParameters: scopes.contains('manage') ? {'scope': 'all'} : null,
      ),
      headers: h,
    ) as Map;
    _requests.value = [
      for (final r in (reqs['items'] as List).cast<Map>().take(40))
        _Req(
          (r['user_name'] as String?) ?? (me['name'] as String? ?? 'you'),
          (r['title'] as String?) ?? '?',
          (r['status'] as String?) ?? '?',
          r['reason'] as String?,
        ),
    ];
  } catch (_) {}
  return _FlowState(user: me['name'] as String?, scopes: scopes);
}

class _ScheduleTab extends StatefulWidget {
  final bool online;
  final VoidCallback onPlay;
  final void Function(String text) onToast;
  const _ScheduleTab({
    required this.online,
    required this.onPlay,
    required this.onToast,
  });

  @override
  State<_ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<_ScheduleTab> {
  List<_Airing> _items = const [];
  String? _anilistError;

  /// Set when AniList refused and cached data from then is shown.
  DateTime? _staleSince;
  _FlowState? _flow;
  bool _loading = true;
  final _scroll = ScrollController();
  String _filter = 'Jellyfin';
  bool _compact = false;
  bool _niche = false;
  bool _sheet = false;
  final _requested = <String>{};
  static const _colW = 252.0;

  late final DateTime _start = () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(
      Duration(days: today.weekday - 1 + 7),
    ); // last week's Monday
  }();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final http = HttpClient();
    final end = _start.add(const Duration(days: 28));
    try {
      final (raw, staleSince) = await _anilistRaw(http, _start, end);
      final items = _airingsFrom(raw);
      _staleSince = staleSince;
      _FlowState flow;
      try {
        flow = await _overlayAnimeFlow(http, items, _start, end);
      } catch (e) {
        flow = _FlowState(error: 'AnimeFlow: $e');
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _flow = flow;
        _loading = false;
        if (flow.error != null) _filter = 'All';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToday());
    } catch (e) {
      if (mounted) {
        setState(() {
          _anilistError = '$e';
          _loading = false;
        });
      }
    } finally {
      http.close();
    }
  }

  void _jumpToday({bool animate = false}) {
    if (!_scroll.hasClients) return;
    final x = (7 * (_colW + 12) - 12).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    animate
        ? _scroll.animateTo(x, duration: _easeTime, curve: _ease)
        : _scroll.jumpTo(x);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<_Airing> get _shown => _items
      .where(
        (a) => switch (_filter) {
          'Jellyfin' => a.tracked,
          'Following' => a.followed,
          _ => _niche || a.popularity >= 5000 || a.tracked,
        },
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [for (var d = 0; d < 28; d++) _start.add(Duration(days: d))];
    final shown = _shown;
    final flow = _flow;
    final owner = flow?.scopes.contains('manage') ?? false;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: 'Jellyfin',
                icon: Icon(Icons.video_library_outlined),
                label: Text('On Jellyfin'),
              ),
              ButtonSegment(
                value: 'Following',
                icon: Icon(Icons.bookmark_outline),
                label: Text('Following'),
              ),
              ButtonSegment(
                value: 'All',
                icon: Icon(Icons.public),
                label: Text('All airing'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
          FilterChip(
            label: const Text('Compact'),
            selected: _compact,
            onSelected: (v) => setState(() => _compact = v),
          ),
          if (_filter == 'All')
            FilterChip(
              label: const Text('Niche too'),
              selected: _niche,
              onSelected: (v) => setState(() => _niche = v),
            ),
          TextButton.icon(
            onPressed: () => _jumpToday(animate: true),
            icon: const Icon(Icons.today, size: 18),
            label: const Text('Today'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _sheet = !_sheet),
            icon: const Icon(Icons.inbox_outlined, size: 18),
            label: Text(owner ? 'Requests' : 'My requests'),
          ),
          if (_staleSince != null)
            _Pill(
              'AniList busy · showing data from '
              '${_staleSince!.hour.toString().padLeft(2, '0')}:${_staleSince!.minute.toString().padLeft(2, '0')}',
              Colors.amber,
            ),
          if (flow != null)
            flow.error != null
                ? _Pill(flow.error!, Colors.orangeAccent)
                : _Pill(
                    'AnimeFlow · ${flow.user} · ${flow.scopes.join(', ')}',
                    Colors.greenAccent.shade400,
                  ),
        ],
      ),
    );
    Widget board;
    if (_loading) {
      board = const Center(child: CircularProgressIndicator());
    } else if (_anilistError != null) {
      board = Center(
        child: Text(
          'AniList unreachable: $_anilistError',
          style: TextStyle(color: scheme.error),
        ),
      );
    } else {
      board = _HScroll(
        controller: _scroll,
        builder: (c) => ListView.separated(
          controller: c,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          itemCount: days.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final d = days[i];
            final items = shown
                .where(
                  (a) =>
                      a.at.year == d.year &&
                      a.at.month == d.month &&
                      a.at.day == d.day,
                )
                .toList();
            return SizedBox(
              width: _colW,
              child: _DayColumn(
                day: d,
                today: d == today,
                past: d.isBefore(today),
                items: items,
                compact: _compact,
                online: widget.online,
                requested: _requested,
                onPlay: (a) {
                  _playMedia(_DemoMedia(a.title, 'Episode ${a.episode}'));
                  widget.onPlay();
                },
                onRequest: (a) {
                  setState(() => _requested.add('${a.anilistId}#${a.episode}'));
                  _requests.value = [
                    _Req(
                      _me.value.name,
                      a.tracked
                          ? '${a.title} E${a.episode}'
                          : '${a.title} · track series',
                      'approved',
                    ),
                    ..._requests.value,
                  ];
                  widget.onToast(
                    'Demo: would request ${a.title} (nothing sent)',
                  );
                },
              ),
            );
          },
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            children: [
              header,
              Expanded(child: board),
            ],
          ),
        ),
        ClipRect(
          child: AnimatedContainer(
            duration: _easeTime,
            curve: _ease,
            width: _sheet ? 360 : 0,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 360,
              maxWidth: 360,
              child: _RequestsSheet(
                owner: owner,
                onClose: () => setState(() => _sheet = false),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  final DateTime day;
  final bool today, past, compact, online;
  final List<_Airing> items;
  final Set<String> requested;
  final void Function(_Airing) onPlay, onRequest;
  const _DayColumn({
    required this.day,
    required this.today,
    required this.past,
    required this.items,
    required this.compact,
    required this.online,
    required this.requested,
    required this.onPlay,
    required this.onRequest,
  });

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: today
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: today
            ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Text(
                  today ? 'Today' : _wd[day.weekday - 1],
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: today ? scheme.primary : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${day.day}.${day.month}.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                if (items.isNotEmpty)
                  Text(
                    '${items.length}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: past && !today ? 0.85 : 1,
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        '—',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                      itemCount: items.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: compact ? 6 : 10),
                      itemBuilder: (context, i) => _AiringCard(
                        a: items[i],
                        compact: compact,
                        online: online,
                        requested: requested.contains(
                          '${items[i].anilistId}#${items[i].episode}',
                        ),
                        onPlay: () => onPlay(items[i]),
                        onRequest: () => onRequest(items[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiringCard extends StatelessWidget {
  final _Airing a;
  final bool compact, online, requested;
  final VoidCallback onPlay, onRequest;
  const _AiringCard({
    required this.a,
    required this.compact,
    required this.online,
    required this.requested,
    required this.onPlay,
    required this.onRequest,
  });

  (String, Color, IconData) _badge() => switch (a.status) {
    _EpStatus.available => (
      'on Jellyfin',
      Colors.greenAccent,
      Icons.check_circle,
    ),
    _EpStatus.downloading => (
      a.progress == null
          ? 'downloading'
          : 'downloading ${(a.progress! * 100).round()}%',
      Colors.lightBlueAccent,
      Icons.downloading,
    ),
    _EpStatus.upcoming => (_countdown(), Colors.amber, Icons.schedule),
    _EpStatus.missing => (
      'missing',
      Colors.orangeAccent,
      Icons.report_gmailerrorred,
    ),
    _EpStatus.failed => (
      'failed${a.reason == null ? '' : ' · ${a.reason}'}',
      Colors.redAccent,
      Icons.error_outline,
    ),
    _EpStatus.unmonitored => (
      'not monitored',
      Colors.grey,
      Icons.visibility_off_outlined,
    ),
    _EpStatus.notTracked => ('not in AnimeFlow', Colors.grey, Icons.public),
  };

  String _countdown() {
    final d = a.at.difference(DateTime.now());
    if (d.isNegative) return 'aired';
    if (d.inDays > 0) return 'in ${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return 'in ${d.inHours}h ${d.inMinutes % 60}m';
    return 'in ${d.inMinutes}m';
  }

  Widget _image(
    String? url,
    Widget fallback, {
    Alignment align = Alignment.center,
  }) => url == null
      ? fallback
      : Image.network(
          url,
          fit: BoxFit.cover,
          alignment: align,
          errorBuilder: (_, __, ___) => fallback,
        );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = _badge();
    final time =
        '${a.at.hour.toString().padLeft(2, '0')}:${a.at.minute.toString().padLeft(2, '0')}';
    final action = switch (a.status) {
      _EpStatus.available => FilledButton.tonalIcon(
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow, size: 18),
        label: Text(online ? 'Put it up' : 'Play'),
      ),
      _EpStatus.missing || _EpStatus.failed || _EpStatus.notTracked =>
        requested
            ? const OutlinedButton(onPressed: null, child: Text('Requested'))
            : OutlinedButton.icon(
                onPressed: onRequest,
                icon: const Icon(Icons.download, size: 18),
                label: Text(
                  a.status == _EpStatus.notTracked
                      ? 'Request series'
                      : 'Request',
                ),
              ),
      _ => null,
    };
    final tint = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            a.tint.withValues(alpha: 0.85),
            a.tint.withValues(alpha: 0.35),
          ],
        ),
      ),
    );
    if (compact) {
      return Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: a.status == _EpStatus.available ? onPlay : null,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 34,
                    height: 48,
                    child: _image(a.cover, tint),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '$time · E${a.episode}',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: label,
                  child: Icon(icon, size: 16, color: color),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // The cover poster leads: it is what people recognise at a glance.
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: a.status == _EpStatus.available ? onPlay : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 84,
                      height: 120,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _image(a.cover, tint),
                          Positioned(
                            left: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                time,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          if (a.status == _EpStatus.downloading)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: a.progress,
                                minHeight: 3,
                                color: Colors.lightBlueAccent,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 120,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                'Episode ${a.episode}',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                              if (a.followed) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.bookmark,
                                  size: 14,
                                  color: scheme.primary,
                                ),
                              ],
                            ],
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Icon(icon, size: 14, color: color),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: color, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (action != null) ...[
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: action),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RequestsSheet extends StatelessWidget {
  final bool owner;
  final VoidCallback onClose;
  const _RequestsSheet({required this.owner, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: ValueListenableBuilder(
        valueListenable: _requests,
        builder: (context, reqs, _) {
          Widget tile(_Req r) {
            final color = switch (r.status) {
              'pending' || 'searching' => Colors.amber,
              'approved' => Colors.lightBlueAccent,
              'rejected' || 'failed' => Colors.redAccent,
              _ => Colors.greenAccent,
            };
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(
                    member: _members.firstWhere(
                      (m) => m.name == r.who,
                      orElse: () => _Member(r.who, Colors.blueGrey),
                    ),
                    size: 32,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.what,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              r.who,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            _Pill(r.status, color),
                          ],
                        ),
                        if (r.reason != null)
                          Text(
                            r.reason!,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        if (owner &&
                            (r.status == 'failed' ||
                                r.status == 'approved' ||
                                r.status == 'searching'))
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                if (r.status == 'failed')
                                  FilledButton.tonal(
                                    onPressed: () {},
                                    child: const Text('Retry'),
                                  ),
                                if (r.status != 'failed')
                                  TextButton(
                                    onPressed: () {},
                                    child: const Text('Decline'),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 16),
            children: [
              Row(
                children: [
                  Text(
                    owner ? 'Requests' : 'My requests',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Text(
                owner
                    ? 'Everyone\'s requests, read from AnimeFlow. Requests are approved automatically; '
                          'you can decline or retry. (Demo: these buttons do nothing.)'
                    : 'AnimeFlow downloads requests automatically; they appear on Jellyfin when done.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (reqs.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Center(
                    child: Text(
                      'No requests yet',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              for (final r in reqs) tile(r),
            ],
          );
        },
      ),
    );
  }
}
