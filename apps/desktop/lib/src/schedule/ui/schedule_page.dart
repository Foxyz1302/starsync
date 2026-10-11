import 'dart:async';

import 'package:flutter/material.dart';

import '../../jellyfin/accounts.dart';
import '../../screens/home/picked_media.dart';
import '../../shell/avatar.dart';
import '../../shell/motion.dart';
import '../../widgets/app_menu.dart';
import '../anilist.dart';
import '../animeflow.dart';
import '../schedule_model.dart';
import 'requests_sheet.dart';
import 'schedule_actions.dart';
import 'schedule_card.dart';

// The Schedule tab: one column per day from last week's Monday to four
// weeks out (AniList), each airing with what AnimeFlow has of it, and the
// one thing to do about it (put it up, request it; right-click an
// available one to queue it). Refreshes every minute while visible; ETags
// keep that cheap.

enum ScheduleFilter { jellyfin, all }

class SchedulePage extends StatefulWidget {
  /// Nobody else watches (offline or solo): available episodes say Play
  /// (offline that starts a solo session).
  final bool solo;

  /// Puts a Jellyfin episode up in the server; returns an error to show.
  final Future<String?> Function(JellyfinMedia pick) onPutUp;

  /// Adds an episode to Up next; null: no server, the cards have no menu.
  final AddToQueue? onAddToQueue;
  final void Function(String message) onToast;

  /// Null = the page makes (and closes) its own.
  final ScheduleRepository? repository;

  /// Linked Jellyfin servers for Put it up; null = [JellyfinAccounts.instance].
  final JellyfinAccounts? accounts;

  const SchedulePage({
    super.key,
    this.solo = false,
    required this.onPutUp,
    this.onAddToQueue,
    required this.onToast,
    this.repository,
    this.accounts,
  });

  static const columnWidth = 252.0;
  static const columnGap = 12.0;
  static const refreshEvery = Duration(seconds: 60);

  /// "All airing" hides entries below this AniList popularity unless
  /// "Niche too" is on (tracked ones always show).
  static const nicheBelow = 5000;
  static const sheetWidth = 360.0;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late final ScheduleRepository _repo;
  late final bool _ownsRepo;
  ScheduleSnapshot? _snap;
  bool _refreshing = false;
  int _gen = 0;
  Timer? _timer;
  final _scroll = ScrollController();
  bool _jumped = false;

  ScheduleFilter _filter = ScheduleFilter.jellyfin;
  bool _compact = false;
  bool _niche = false;
  bool _sheet = false;

  /// The sheet stays built while it slides out.
  bool _sheetBuilt = false;


  /// Requested in this run: "anilistId#episode" or "series:anilistId".
  final _requested = <String>{};

  /// Cards with a call in flight (same keys as [_requested], "play:...").
  final _busy = <String>{};

  List<AnimeFlowRequest>? _requests;
  String? _requestsError;
  final _reqBusy = <int>{};

  JellyfinAccounts get _accounts => widget.accounts ?? JellyfinAccounts.instance;
  AnimeFlowClient? get _flow => _repo.animeFlow;
  AnimeFlowMe? get _me => _snap?.me;
  bool get _owner => _me?.can(AnimeFlowScope.manage) ?? false;

  @override
  void initState() {
    super.initState();
    _ownsRepo = widget.repository == null;
    _repo = widget.repository ?? _ownRepo();
    _load();
    _timer = Timer.periodic(SchedulePage.refreshEvery, (_) {
      if (mounted && !_refreshing && TickerMode.valuesOf(context).enabled) _load();
    });
  }

  ScheduleRepository _ownRepo() {
    final flow = AnimeFlowClient.fromAccounts(_accounts);
    return ScheduleRepository(
      aniList: AniListClient(),
      animeFlow: flow,
      jellyfinEpisodes: (id) => jellyfinEpisodeNumbers(_accounts, flow, id),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    if (_ownsRepo) {
      _repo.aniList.close();
      _repo.animeFlow?.close();
    }
    super.dispose();
  }

  void _toast(String s) {
    if (mounted) widget.onToast(s);
  }

  Future<void> _load({bool force = false}) async {
    final gen = ++_gen;
    if (_snap != null) setState(() => _refreshing = true);
    final snap = await _repo.load(force: force);
    if (!mounted || gen != _gen) return;
    final first = _snap == null;
    setState(() {
      _snap = snap;
      _refreshing = false;
      // Without AnimeFlow nothing is "on Jellyfin": start on everything.
      if (first && !snap.hasAnimeFlow) _filter = ScheduleFilter.all;
    });
    if (!_jumped && snap.entries.isNotEmpty) {
      _jumped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToday());
    }
    await _loadRequests();
  }

  Future<void> _loadRequests() async {
    final c = _flow, me = _me;
    if (c == null || me == null) {
      if (_requests != null || _requestsError != null) {
        setState(() {
          _requests = null;
          _requestsError = null;
        });
      }
      return;
    }
    try {
      final reqs = await c.requests(all: me.can(AnimeFlowScope.manage));
      if (mounted) {
        setState(() {
          _requests = reqs;
          _requestsError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _requestsError = friendlyError(e));
    }
  }

  // ------------------------------------------------------------- layout

  int _todayIndex(DateTime from) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final f = DateTime(from.year, from.month, from.day);
    return (today.difference(f).inHours / 24).round();
  }

  void _jumpToday({bool animate = false}) {
    final snap = _snap;
    if (!_scroll.hasClients || snap == null) return;
    final i = _todayIndex(snap.from.toLocal());
    final x = (i * (SchedulePage.columnWidth + SchedulePage.columnGap))
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    animate ? _scroll.animateTo(x, duration: easeTime, curve: ease) : _scroll.jumpTo(x);
  }

  bool _shows(ScheduleEntry e) => switch (_filter) {
    ScheduleFilter.jellyfin => e.tracked || e.onJellyfin,
    ScheduleFilter.all => _niche || e.tracked || e.airing.popularity >= SchedulePage.nicheBelow,
  };

  static String _key(ScheduleEntry e) =>
      e.tracked ? '${e.airing.anilistId}#${e.airing.episode}' : 'series:${e.airing.anilistId}';

  static const _active = {RequestStatus.pending, RequestStatus.approved, RequestStatus.searching};

  bool _isRequested(ScheduleEntry e) {
    if (_requested.contains(_key(e))) return true;
    final a = e.airing;
    for (final r in _requests ?? const <AnimeFlowRequest>[]) {
      if (!_active.contains(r.status)) continue;
      if (e.tracked) {
        if (r.kind == RequestKind.episode && r.seriesId == e.seriesId && r.episode == a.episode) return true;
        if (r.kind == RequestKind.season && r.seriesId == e.seriesId && r.season == e.season) return true;
      } else if (r.kind == RequestKind.series && (r.title == a.title || r.title == a.titleRomaji)) {
        return true;
      }
    }
    return false;
  }

  (CardAction, String?) _actionFor(ScheduleEntry e) {
    if (e.status == ScheduleStatus.available || e.status == ScheduleStatus.inLibrary) {
      final put = widget.solo ? CardAction.play : CardAction.putUp;
      if (e.jellyfinSeriesId == null) return (put, 'Not linked to a Jellyfin series yet');
      return (put, null);
    }
    final me = _me;
    final CardAction kind;
    if (e.tracked) {
      kind = e.status == ScheduleStatus.missing || e.status == ScheduleStatus.failed
          ? CardAction.request
          : CardAction.none;
    } else {
      // On Jellyfin already (owner added it by hand): nothing to request.
      kind = me != null && !e.onJellyfin ? CardAction.requestSeries : CardAction.none;
    }
    if (kind == CardAction.none) return (kind, null);
    if (_isRequested(e)) return (CardAction.requested, null);
    if (me == null || !me.can(AnimeFlowScope.request)) {
      return (kind, 'Requests need the owner to allow them for you on AnimeFlow');
    }
    return (kind, null);
  }

  // ------------------------------------------------------------- actions

  Future<void> _onAction(ScheduleEntry e, CardAction action) async {
    switch (action) {
      case CardAction.putUp:
      case CardAction.play:
        return _putUp(e);
      case CardAction.request:
      case CardAction.requestSeries:
        return _request(e);
      default:
        return;
    }
  }

  Future<void> _putUp(ScheduleEntry e) async {
    final key = 'play:${_key(e)}';
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      final pick = await resolveJellyfinEpisode(_accounts, _flow, e);
      final err = await widget.onPutUp(pick);
      if (err != null) _toast(err);
    } catch (err) {
      _toast(friendlyError(err));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// Right-click on an available episode ([context]: its card): Put it
  /// up, Add to queue, Play next.
  Future<void> _menu(BuildContext context, ScheduleEntry e) async {
    final add = widget.onAddToQueue;
    if (add == null) return;
    final pick = await showAppMenu<int>(context, items: [
      AppMenuItem(value: 0, label: widget.solo ? 'Play' : 'Put it up'),
      const AppMenuItem(value: 1, label: 'Add to queue'),
      const AppMenuItem(value: 2, label: 'Play next'),
    ]);
    if (pick == null || !mounted) return;
    if (pick == 0) return _putUp(e);
    final key = 'play:${_key(e)}';
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      final media = await resolveJellyfinEpisode(_accounts, _flow, e);
      final err = await add(media, next: pick == 2);
      if (err != null) _toast(err);
    } catch (err) {
      _toast(friendlyError(err));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _request(ScheduleEntry e) async {
    final c = _flow;
    if (c == null) return;
    final key = _key(e);
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    final a = e.airing;
    try {
      final seriesId = e.seriesId;
      if (e.tracked && seriesId != null) {
        final n = await flowNumbering(c, e);
        await c.requestEpisode(seriesId, n.season, n.episode);
        _requested.add(key);
        _toast('Requested ${a.title}, episode ${a.episode}');
      } else {
        final found = await findOnAniDb(c, a);
        final hit = found.match ?? (mounted ? await _chooseHit(a, found.hits) : null);
        if (hit == null) return;
        await c.requestSeries(hit.anidbId);
        _requested.add(key);
        _toast('Requested ${hit.title}');
      }
      unawaited(_loadRequests());
    } on AnimeFlowException catch (err) {
      if (err.code == AnimeFlowErrorCode.alreadyRequested) _requested.add(key);
      _toast(friendlyError(err));
    } catch (err) {
      _toast(friendlyError(err));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// No search hit has [a]'s AniList id: let the user pick one (or learn
  /// that AniDB does not know it).
  Future<AnimeFlowSearchHit?> _chooseHit(Airing a, List<AnimeFlowSearchHit> hits) => showDialog<AnimeFlowSearchHit>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        key: const ValueKey('anidb-choose'),
        title: Text(hits.isEmpty ? 'Not found on AniDB' : 'Which one is "${a.title}"?'),
        content: SizedBox(
          width: 420,
          child: hits.isEmpty
              ? Text(
                  'AnimeFlow can only add series AniDB knows, and its search found nothing for this title.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final h in hits)
                      ListTile(
                        key: ValueKey('anidb-${h.anidbId}'),
                        title: Text(h.title),
                        subtitle: Text('AniDB ${h.anidbId}${h.seriesId != null ? ' · already on AnimeFlow' : ''}'),
                        onTap: () => Navigator.of(context).pop(h),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(hits.isEmpty ? 'OK' : 'Cancel')),
        ],
      );
    },
  );

  Future<void> _decide(AnimeFlowRequest r, {required bool approve}) async {
    final c = _flow;
    if (c == null || _reqBusy.contains(r.id)) return;
    setState(() => _reqBusy.add(r.id));
    try {
      approve ? await c.approve(r.id) : await c.reject(r.id);
      _toast(approve ? 'Retrying ${r.title}' : 'Declined ${r.title}');
      await _loadRequests();
    } catch (err) {
      _toast(friendlyError(err));
    } finally {
      if (mounted) setState(() => _reqBusy.remove(r.id));
    }
  }

  // ------------------------------------------------------------- build

  Widget _header(BuildContext context) {
    final snap = _snap;
    final me = _me;
    final stale = snap?.aniListStaleSince;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<ScheduleFilter>(
            key: const ValueKey('schedule-filter'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ScheduleFilter.jellyfin,
                icon: Icon(Icons.video_library_outlined),
                label: Text('On Jellyfin'),
              ),
              ButtonSegment(value: ScheduleFilter.all, icon: Icon(Icons.public), label: Text('All airing')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
          FilterChip(
            key: const ValueKey('schedule-compact'),
            label: const Text('Compact'),
            selected: _compact,
            onSelected: (v) => setState(() => _compact = v),
          ),
          if (_filter == ScheduleFilter.all)
            FilterChip(
              key: const ValueKey('schedule-niche'),
              label: const Text('Niche too'),
              selected: _niche,
              onSelected: (v) => setState(() => _niche = v),
            ),
          TextButton.icon(
            key: const ValueKey('schedule-today'),
            onPressed: () => _jumpToday(animate: true),
            icon: const Icon(Icons.today, size: 18),
            label: const Text('Today'),
          ),
          IconButton(
            key: const ValueKey('schedule-refresh'),
            tooltip: 'Refresh',
            onPressed: _refreshing || snap == null ? null : () => _load(force: true),
            icon: _refreshing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 20),
          ),
          Tooltip(
            message: me == null ? (snap?.animeFlowError ?? 'AnimeFlow is not available') : '',
            child: OutlinedButton.icon(
              key: const ValueKey('schedule-requests'),
              onPressed: me == null
                  ? null
                  : () => setState(() {
                      _sheet = !_sheet;
                      if (_sheet) _sheetBuilt = true;
                    }),
              icon: const Icon(Icons.inbox_outlined, size: 18),
              label: Text(_owner ? 'Requests' : 'My requests'),
            ),
          ),
          if (stale != null)
            Pill(
              key: const ValueKey('schedule-stale'),
              'AniList busy · showing data from ${clockText(stale)}',
              Colors.amber,
            ),
          if (me != null)
            Pill(
              key: const ValueKey('schedule-animeflow'),
              'AnimeFlow · ${me.name} · ${[for (final s in AnimeFlowScope.values)
                if (me.can(s)) s.name].join(', ')}',
              Colors.greenAccent.shade400,
            )
          else if (snap?.animeFlowError != null)
            Pill(key: const ValueKey('schedule-animeflow'), snap!.animeFlowError!, Colors.orangeAccent),
        ],
      ),
    );
  }

  Widget _board(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snap = _snap;
    if (snap == null) return const Center(child: CircularProgressIndicator());
    if (snap.aniListError != null && snap.entries.isEmpty) {
      return Center(
        key: const ValueKey('schedule-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, color: scheme.error),
              const SizedBox(height: 8),
              Text(
                'Could not load the schedule: ${snap.aniListError}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _refreshing ? null : () => _load(force: true),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = snap.from.toLocal();
    final start = DateTime(from.year, from.month, from.day);
    final to = snap.to.toLocal();
    final count = (DateTime(to.year, to.month, to.day).difference(start).inHours / 24).round().clamp(1, 60);
    final days = [for (var d = 0; d < count; d++) DateTime(start.year, start.month, start.day + d)];
    final byDay = <DateTime, List<ScheduleEntry>>{};
    for (final e in snap.entries) {
      if (!_shows(e)) continue;
      final l = e.airing.airingAt.toLocal();
      (byDay[DateTime(l.year, l.month, l.day)] ??= []).add(e);
    }
    return HScroll(
      controller: _scroll,
      builder: (c) => ListView.separated(
        key: const ValueKey('schedule-board'),
        controller: c,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: SchedulePage.columnGap),
        itemBuilder: (context, i) {
          final d = days[i];
          final items = byDay[d] ?? const <ScheduleEntry>[];
          return SizedBox(
            key: ValueKey('day-${d.year}-${d.month}-${d.day}'),
            width: SchedulePage.columnWidth,
            child: DayColumn(
              day: d,
              today: d == today,
              past: d.isBefore(today),
              compact: _compact,
              cards: [for (final e in items) _card(e, now)],
            ),
          );
        },
      ),
    );
  }

  Widget _card(ScheduleEntry e, DateTime now) {
    final (action, hint) = _actionFor(e);
    final busy = _busy.contains(action == CardAction.putUp || action == CardAction.play ? 'play:${_key(e)}' : _key(e));
    return AiringCard(
      entry: e,
      now: now,
      compact: _compact,
      action: action,
      disabledHint: hint,
      busy: busy,
      onAction: () => _onAction(e, action),
      onMenu: widget.onAddToQueue != null && (action == CardAction.putUp || action == CardAction.play) && hint == null
          ? (context) => _menu(context, e)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          children: [
            _header(context),
            Expanded(child: _board(context)),
          ],
        ),
      ),
      ClipRect(
        child: AnimatedContainer(
          duration: easeTime,
          curve: ease,
          width: _sheet ? SchedulePage.sheetWidth : 0,
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: SchedulePage.sheetWidth,
            maxWidth: SchedulePage.sheetWidth,
            child: _sheetBuilt && _me != null
                ? RequestsSheet(
                    key: const ValueKey('requests-sheet'),
                    owner: _owner,
                    requests: _requests,
                    error: _requestsError,
                    selfName: _me?.name ?? '',
                    busy: _reqBusy,
                    onRetry: (r) => _decide(r, approve: true),
                    onDecline: (r) => _decide(r, approve: false),
                    onClose: () => setState(() => _sheet = false),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ],
  );
}
