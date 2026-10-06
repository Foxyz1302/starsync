import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/picked_media.dart';
import 'accounts.dart';
import 'browse_scope.dart';
import 'detail_page.dart';
import 'format.dart';
import 'home_page.dart';
import 'inspector.dart';
import 'library_page.dart';
import 'search_results.dart';
import 'series_page.dart';
import 'sign_in_panel.dart';

/// Browser width from which the inspector pane shows on the right.
const inspectorFrom = 1400.0;
const inspectorWidth = 340.0;

/// Library browser for the linked Jellyfin servers: server switcher,
/// breadcrumbs, search, and a back stack of pages (Home rows, library
/// grids, series, details). Pages below the top stay alive, so going back
/// keeps scroll position and loaded pages.
///
/// Keyboard: arrows move between cards, Enter picks / opens, I opens
/// details, Esc / Backspace / Alt+Left go back, / or Ctrl+F searches.
class JellyfinBrowser extends StatefulWidget {
  final JellyfinAccounts accounts;
  final JellyfinMedia? selected;
  final ValueChanged<JellyfinMedia> onPick;
  /// Shown when given: toggles a bigger browser (the host hides its form).
  final VoidCallback? onToggleExpanded;
  final bool expanded;
  final VoidCallback? onOpenIntegrations;
  final Duration searchDebounce;
  /// Opens here instead of the remembered location (the series of the
  /// episode playing, in the session's swap panel).
  final BrowseStart? start;
  const JellyfinBrowser({
    this.start,
    super.key,
    required this.accounts,
    required this.onPick,
    this.selected,
    this.onToggleExpanded,
    this.expanded = false,
    this.onOpenIntegrations,
    this.searchDebounce = const Duration(milliseconds: 300),
  });

  @override
  State<JellyfinBrowser> createState() => _JellyfinBrowserState();
}

class _JellyfinBrowserState extends State<JellyfinBrowser> {
  String? _serverId;
  List<BrowseRoute> _stack = const [HomeRoute()];
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'jf-search');
  final _body = FocusScopeNode(debugLabel: 'jf-body');
  final _peek = ValueNotifier<JellyfinItem?>(null);
  String _term = '';
  Timer? _debounce;
  int _refresh = 0;

  JellyfinAccounts get _accounts => widget.accounts;

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    if (start != null && _accounts.account(start.serverId) != null) {
      _serverId = start.serverId;
      _stack = start.stack.isEmpty ? const [HomeRoute()] : start.stack;
      _remember();
    } else {
      _serverId = widget.selected != null && _accounts.account(widget.selected!.serverId) != null
          ? widget.selected!.serverId
          : _accounts.defaultServerId;
      _stack = _restored(_serverId);
    }
    _accounts.addListener(_changed);
  }

  /// The remembered location on [serverId], else Home.
  List<BrowseRoute> _restored(String? serverId) =>
      (serverId == null ? null : decodeBrowseStack(_accounts.browseLocation(serverId))) ??
      const [HomeRoute()];

  /// Every navigation is saved per server (Hive), so the next browser
  /// (Host tab, swap panel, next start) opens where this one was.
  void _remember() {
    final id = _account?.serverId;
    if (id != null) unawaited(_accounts.saveBrowseLocation(id, encodeBrowseStack(_stack)));
  }

  @override
  void didUpdateWidget(JellyfinBrowser old) {
    super.didUpdateWidget(old);
    if (old.accounts != widget.accounts) {
      old.accounts.removeListener(_changed);
      widget.accounts.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _accounts.removeListener(_changed);
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _body.dispose();
    _peek.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  JellyfinAccount? get _account =>
      (_serverId == null ? null : _accounts.account(_serverId!)) ?? _accounts.defaultAccount;

  void _switchServer(String serverId) {
    if (serverId == _account?.serverId) return;
    setState(() {
      _serverId = serverId;
      _stack = _restored(serverId);
      _peek.value = null;
      _clearSearch();
    });
  }

  // ------------------------------------------------------------- navigation

  void _open(BrowseRoute route) {
    setState(() {
      _clearSearch();
      if (_stack.last.key != route.key) _stack = [..._stack, route];
    });
    _remember();
    _body.requestFocus();
  }

  bool _back() {
    if (_stack.length <= 1) return false;
    setState(() => _stack = _stack.sublist(0, _stack.length - 1));
    _remember();
    _body.requestFocus();
    return true;
  }

  void _popTo(int index) {
    setState(() {
      _clearSearch();
      _stack = _stack.sublist(0, index + 1);
    });
    _remember();
    _body.requestFocus();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(widget.searchDebounce, () {
      if (mounted) setState(() => _term = text.trim());
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    _term = '';
  }

  void _pick(JellyfinItem item) {
    final account = _account;
    if (account == null) return;
    widget.onPick(pickFor(account, item));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final inField = FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      if (_search.text.isNotEmpty || _term.isNotEmpty) {
        setState(_clearSearch);
        _body.requestFocus();
        return KeyEventResult.handled;
      }
      if (inField) {
        _body.requestFocus();
        return KeyEventResult.handled;
      }
      return _back() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (inField) return KeyEventResult.ignored;
    if (e.character == '/' || (keys.isControlPressed && k == LogicalKeyboardKey.keyF)) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace ||
        (keys.isAltPressed && k == LogicalKeyboardKey.arrowLeft) ||
        k == LogicalKeyboardKey.browserBack) {
      return _back() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ build

  Widget _page(BrowseRoute r) => switch (r) {
        HomeRoute() => const JellyfinHomePage(),
        LibraryRoute(:final folder) => JellyfinLibraryPage(folder: folder),
        SeriesRoute(:final series, :final seasonId) =>
          JellyfinSeriesPage(series: series, seasonId: seasonId),
        DetailRoute(:final item) => JellyfinDetailPage(item: item),
      };

  @override
  Widget build(BuildContext context) {
    final account = _account;
    if (account == null) {
      return const Center(child: Text('No Jellyfin server linked', style: TextStyle(color: Colors.grey)));
    }
    final client = _accounts.clientFor(account.serverId)!;
    final status = _accounts.statusOf(account.serverId);
    final sel = widget.selected;
    final searching = _term.isNotEmpty;

    final pages = Stack(
      children: [
        for (var i = 0; i < _stack.length; i++)
          Visibility(
            key: ValueKey('$_refresh:${account.serverId}:$i:${_stack[i].key}'),
            visible: !searching && i == _stack.length - 1,
            maintainState: true,
            child: _page(_stack[i]),
          ),
        if (searching) JellyfinSearchResults(key: ValueKey('$_refresh:$_term'), term: _term),
      ],
    );

    return BrowseScope(
      accounts: _accounts,
      account: account,
      client: client,
      selectedItemId: sel != null && sel.serverId == account.serverId ? sel.itemId : null,
      onPick: _pick,
      onOpen: _open,
      onPeek: (item) => _peek.value = item,
      child: Focus(
        onKeyEvent: _onKey,
        child: Column(
          key: const ValueKey('jf-browser'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, account),
            if (status == JellyfinAccountStatus.expired || status == JellyfinAccountStatus.offline)
              _StatusBanner(accounts: _accounts, account: account, status: status),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final inspector = box.maxWidth >= inspectorFrom;
                final body = FocusScope(node: _body, child: pages);
                if (!inspector) return body;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: body),
                    const SizedBox(width: 16),
                    SizedBox(width: inspectorWidth, child: JellyfinInspector(item: _peek)),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, JellyfinAccount account) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final crumbs = <Widget>[];
    for (var i = 0; i < _stack.length; i++) {
      final last = i == _stack.length - 1 && _term.isEmpty;
      if (i > 0) {
        crumbs.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.chevron_right, size: 18, color: Colors.grey),
        ));
      }
      final label = Text(
        _stack[i].label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.titleSmall?.copyWith(
            color: last ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
            fontWeight: last ? FontWeight.w600 : null),
      );
      crumbs.add(Flexible(
        child: last
            ? label
            : InkWell(
                key: ValueKey('crumb-$i'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => _popTo(i),
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), child: label),
              ),
      ));
    }
    if (_term.isNotEmpty) {
      crumbs
        ..add(const Icon(Icons.chevron_right, size: 18, color: Colors.grey))
        ..add(Flexible(
            child: Text('Search “$_term”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600))));
    }

    return Row(
      children: [
        _ServerSwitcher(
          accounts: _accounts,
          current: account,
          onSelect: _switchServer,
          onOpenIntegrations: widget.onOpenIntegrations,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Back (Esc)',
          visualDensity: VisualDensity.compact,
          onPressed: _stack.length > 1 ? _back : null,
          icon: const Icon(Icons.arrow_back, size: 20),
        ),
        const SizedBox(width: 4),
        Expanded(child: Row(children: crumbs)),
        const SizedBox(width: 8),
        SizedBox(
          width: 260,
          child: TextField(
            key: const ValueKey('jf-search'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: _onSearchChanged,
            onSubmitted: (v) {
              _debounce?.cancel();
              setState(() => _term = v.trim());
            },
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search  ( / )',
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              suffixIcon: ListenableBuilder(
                listenable: _search,
                builder: (context, _) => _search.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear (Esc)',
                        iconSize: 16,
                        onPressed: () => setState(_clearSearch),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          onPressed: () {
            _accounts.invalidate(account.serverId);
            setState(() => _refresh++);
          },
          icon: const Icon(Icons.refresh, size: 20),
        ),
        if (widget.onToggleExpanded != null)
          IconButton(
            key: const ValueKey('jf-expand'),
            tooltip: widget.expanded ? 'Show the host form' : 'Bigger browser',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onToggleExpanded,
            icon: Icon(widget.expanded ? Icons.close_fullscreen : Icons.open_in_full, size: 18),
          ),
      ],
    );
  }
}

/// Current server (avatar + name); a menu when several are linked.
class _ServerSwitcher extends StatelessWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount current;
  final ValueChanged<String> onSelect;
  final VoidCallback? onOpenIntegrations;
  const _ServerSwitcher({
    required this.accounts,
    required this.current,
    required this.onSelect,
    this.onOpenIntegrations,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(status: accounts.statusOf(current.serverId)),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(current.displayName,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
        ),
      ],
    );
    if (accounts.accounts.length < 2 && onOpenIntegrations == null) {
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: chip);
    }
    return MenuAnchor(
      menuChildren: [
        for (final a in accounts.accounts)
          MenuItemButton(
            key: ValueKey('server-${a.serverId}'),
            leadingIcon: StatusDot(status: accounts.statusOf(a.serverId)),
            trailingIcon: a.serverId == current.serverId ? const Icon(Icons.check, size: 18) : null,
            onPressed: () => onSelect(a.serverId),
            child: Text('${a.displayName}  ·  ${a.userName}'),
          ),
        if (onOpenIntegrations != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.add, size: 18),
            onPressed: onOpenIntegrations,
            child: const Text('Manage servers…'),
          ),
      ],
      builder: (context, menu, _) => TextButton(
        key: const ValueKey('jf-server-switch'),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          chip,
          const Icon(Icons.arrow_drop_down, size: 20),
        ]),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  final JellyfinAccountStatus status;
  const StatusDot({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      JellyfinAccountStatus.online => Colors.green,
      JellyfinAccountStatus.offline => Colors.orange,
      JellyfinAccountStatus.expired => Theme.of(context).colorScheme.error,
      _ => Colors.grey,
    };
    return Container(
        width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _StatusBanner extends StatelessWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount account;
  final JellyfinAccountStatus status;
  const _StatusBanner({required this.accounts, required this.account, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = status == JellyfinAccountStatus.expired;
    return Container(
      key: const ValueKey('jf-status-banner'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (expired ? scheme.errorContainer : Colors.orange.shade900).withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(expired ? Icons.lock_clock : Icons.cloud_off, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(expired
                ? 'Sign-in to ${account.displayName} expired. Reconnect to keep browsing.'
                : "Can't reach ${account.displayName}: ${accounts.errorOf(account.serverId) ?? 'offline'}"),
          ),
          if (expired)
            FilledButton.tonal(
              onPressed: () => showReconnectDialog(context, accounts, account),
              child: const Text('Reconnect'),
            )
          else
            TextButton(
              onPressed: () => accounts.validate(account.serverId),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

/// Sign in again to an expired account (same server, new token).
Future<void> showReconnectDialog(
    BuildContext context, JellyfinAccounts accounts, JellyfinAccount account) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: JellyfinSignInPanel(
            accounts: accounts,
            reconnect: account,
            onDone: (_) => Navigator.of(context).pop(),
            onCancel: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    ),
  );
}

/// Small helper for other screens: the user's avatar on a linked server.
class JellyfinAvatar extends StatelessWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount account;
  final double radius;
  const JellyfinAvatar({super.key, required this.accounts, required this.account, this.radius = 18});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initials = account.userName.isEmpty ? '?' : account.userName.characters.first.toUpperCase();
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      child: Text(initials, style: TextStyle(color: scheme.onPrimaryContainer)),
    );
    final client = accounts.clientFor(account.serverId);
    final url = client?.userImageUrl(account.user, maxWidth: (radius * 4).round());
    if (url == null) return fallback;
    return ClipOval(
      child: SizedBox(
        width: radius * 2,
        height: radius * 2,
        child: Image.network(url.toString(),
            fit: BoxFit.cover,
            cacheWidth: (radius * 4).round(),
            errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}
