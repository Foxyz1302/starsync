import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/picked_media.dart';

// Linked Jellyfin servers, one account per ServerId, in their own Hive box.
//
// Only tokens this app obtained itself (Quick Connect or password through
// [JellyfinSignIn]) are ever stored or used: Jellyfin overwrites a token's
// device name and app version with whatever header comes with it, so
// borrowing another client's token would rename that client's device.

const jellyfinBoxName = 'jellyfin';
const _keyDeviceId = 'deviceId';
const _keyAccounts = 'accounts';
const _keyDefault = 'defaultServer';
const _keyLastPick = 'lastPick';
const _keyBrowsePrefix = 'browse:';
const _keyDismissedPrefix = 'dismissed:';

/// One signed-in user on one server.
class JellyfinAccount {
  final String serverId;
  final String serverName;
  final String serverVersion;
  /// Addresses this server was reached at, preferred first.
  final List<String> urls;
  final String userId;
  final String userName;
  final String? userImageTag;
  final String token;
  const JellyfinAccount({
    required this.serverId,
    required this.serverName,
    this.serverVersion = '',
    required this.urls,
    required this.userId,
    required this.userName,
    this.userImageTag,
    required this.token,
  });

  String get baseUrl => urls.first;

  JellyfinUser get user =>
      JellyfinUser(id: userId, name: userName, serverId: serverId, primaryImageTag: userImageTag);

  /// "Example Server" or the host when the server has no name.
  String get displayName =>
      serverName.isNotEmpty ? serverName : (Uri.tryParse(baseUrl)?.host ?? baseUrl);

  JellyfinAccount copyWith({
    String? serverName,
    String? serverVersion,
    List<String>? urls,
    String? userName,
    String? userImageTag,
  }) =>
      JellyfinAccount(
        serverId: serverId,
        serverName: serverName ?? this.serverName,
        serverVersion: serverVersion ?? this.serverVersion,
        urls: urls ?? this.urls,
        userId: userId,
        userName: userName ?? this.userName,
        userImageTag: userImageTag ?? this.userImageTag,
        token: token,
      );

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'serverName': serverName,
        'serverVersion': serverVersion,
        'urls': urls,
        'userId': userId,
        'userName': userName,
        'userImageTag': ?userImageTag,
        'token': token,
      };

  static JellyfinAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final sid = j['serverId'], uid = j['userId'], token = j['token'], urls = j['urls'];
    if (sid is! String || uid is! String || token is! String || urls is! List) return null;
    final list = urls.whereType<String>().toList();
    if (sid.isEmpty || token.isEmpty || list.isEmpty) return null;
    String s(Object? v) => v is String ? v : '';
    return JellyfinAccount(
      serverId: sid,
      serverName: s(j['serverName']),
      serverVersion: s(j['serverVersion']),
      urls: list,
      userId: uid,
      userName: s(j['userName']),
      userImageTag: j['userImageTag'] is String ? j['userImageTag'] as String : null,
      token: token,
    );
  }
}

enum JellyfinAccountStatus {
  /// Not checked yet this run.
  unknown,
  checking,
  online,
  /// Unreachable (network error); the token may still be fine.
  offline,
  /// The server rejected the token: sign in again ("Reconnect").
  expired,
}

/// Key-value persistence behind [JellyfinAccounts]; tests use
/// [MemoryJellyfinStore].
abstract class JellyfinStore {
  Future<void> open();
  Object? get(String key);
  Future<void> put(String key, Object? value);
}

class HiveJellyfinStore implements JellyfinStore {
  HiveJellyfinStore({this.boxName = jellyfinBoxName});
  final String boxName;
  Box? _box;

  @override
  Future<void> open() async => _box ??= await Hive.openBox(boxName);

  @override
  Object? get(String key) => _box?.get(key);

  @override
  Future<void> put(String key, Object? value) async {
    final box = _box;
    if (box == null) return;
    value == null ? await box.delete(key) : await box.put(key, value);
  }
}

class MemoryJellyfinStore implements JellyfinStore {
  final Map<String, Object?> data;
  MemoryJellyfinStore([Map<String, Object?>? data]) : data = data ?? {};

  @override
  Future<void> open() async {}
  @override
  Object? get(String key) => data[key];
  @override
  Future<void> put(String key, Object? value) async =>
      value == null ? data.remove(key) : data[key] = value;
}

/// All linked Jellyfin servers, their live status and one authenticated
/// [JellyfinClient] each. [ensureLoaded] reads the box and then checks every
/// token in the background; a rejected token turns the account
/// [JellyfinAccountStatus.expired] (shown as "Reconnect"), never a silent
/// sign-out.
class JellyfinAccounts extends ChangeNotifier {
  static final JellyfinAccounts instance = JellyfinAccounts();

  JellyfinAccounts({
    JellyfinStore? store,
    this.httpFactory,
    this.deviceName,
  }) : _store = store ?? HiveJellyfinStore();

  final JellyfinStore _store;
  /// Transport for every client made here; null = real HTTP. Tests fake it.
  final JellyfinHttp Function()? httpFactory;
  /// Device name sent to Jellyfin; null = the hostname.
  final String? deviceName;

  List<JellyfinAccount> _accounts = const [];
  final _status = <String, JellyfinAccountStatus>{};
  final _errors = <String, String>{};
  final _clients = <String, JellyfinClient>{};
  final _memo = <String, ({DateTime at, Future<Object?> value})>{};
  String? _defaultServerId;
  String _deviceId = '';
  JellyfinMedia? _lastPick;
  Future<void>? _load;
  bool _loaded = false;
  bool _disposed = false;

  List<JellyfinAccount> get accounts => _accounts;
  bool get loaded => _loaded;
  bool get isEmpty => _accounts.isEmpty;

  JellyfinAccount? account(String serverId) =>
      _accounts.where((a) => a.serverId == serverId).firstOrNull;

  /// [itemId]'s page in the web UI of linked server [serverId] ("Open in
  /// Jellyfin"); null when that server is not linked here.
  String? webUrlOf(String serverId, String itemId) {
    final a = account(serverId);
    return a == null ? null : jellyfinWebUrl(a.baseUrl, itemId, serverId: serverId);
  }

  /// The chosen default, else the first linked server.
  JellyfinAccount? get defaultAccount =>
      (_defaultServerId == null ? null : account(_defaultServerId!)) ?? _accounts.firstOrNull;

  String? get defaultServerId => defaultAccount?.serverId;

  JellyfinAccountStatus statusOf(String serverId) =>
      _status[serverId] ?? JellyfinAccountStatus.unknown;

  /// Last failure text for an offline account.
  String? errorOf(String serverId) => _errors[serverId];

  /// The last Jellyfin pick put up, restored in the Library on the next start.
  JellyfinMedia? get lastPick => _lastPick;

  /// Stable per install: Jellyfin keys devices and tokens by it.
  String get deviceId => _deviceId;

  JellyfinClientInfo get clientInfo => JellyfinClientInfo(
        // The old name on purpose: Jellyfin lists devices under it.
        client: 'Watch Together',
        device: deviceName ?? _hostname(),
        deviceId: _deviceId.isEmpty ? 'unknown' : _deviceId,
        version: appVersion,
      );

  static String _hostname() {
    try {
      final h = Platform.localHostname;
      return h.isEmpty ? 'Desktop' : h;
    } catch (_) {
      return 'Desktop';
    }
  }

  Future<void> ensureLoaded({bool validate = true}) =>
      _load ??= _loadNow(validate: validate);

  Future<void> _loadNow({required bool validate}) async {
    try {
      await _store.open();
      final id = _store.get(_keyDeviceId);
      if (id is String && id.isNotEmpty) {
        _deviceId = id;
      } else {
        _deviceId = _newDeviceId();
        await _store.put(_keyDeviceId, _deviceId);
      }
      _accounts = _decodeAccounts(_store.get(_keyAccounts));
      final def = _store.get(_keyDefault);
      _defaultServerId = def is String ? def : null;
      final pick = _store.get(_keyLastPick);
      _lastPick = pick is String ? JellyfinMedia.fromJson(_tryJson(pick)) : null;
    } catch (e, st) {
      debugPrint('load jellyfin accounts failed: $e\n$st');
      if (_deviceId.isEmpty) _deviceId = _newDeviceId();
    }
    _loaded = true;
    _notify();
    if (validate) unawaited(validateAll());
  }

  static String _newDeviceId() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  static Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static List<JellyfinAccount> _decodeAccounts(Object? raw) {
    if (raw is! String) return const [];
    final list = _tryJson(raw);
    if (list is! List) return const [];
    final out = <JellyfinAccount>[];
    for (final j in list) {
      final a = JellyfinAccount.fromJson(j);
      if (a != null && out.every((o) => o.serverId != a.serverId)) out.add(a);
    }
    return out;
  }

  Future<void> _save() async {
    try {
      await _store.put(_keyAccounts, jsonEncode([for (final a in _accounts) a.toJson()]));
      await _store.put(_keyDefault, _defaultServerId);
    } catch (e, st) {
      debugPrint('save jellyfin accounts failed: $e\n$st');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------- clients

  /// A client without a token, for probing an address and signing in.
  /// The caller closes it.
  JellyfinClient anonymousClient(String baseUrl) =>
      JellyfinClient(baseUrl: baseUrl, clientInfo: clientInfo, http: httpFactory?.call());

  /// The signed-in client of a linked server (null if not linked). Shared;
  /// do not close it.
  JellyfinClient? clientFor(String serverId) {
    final a = account(serverId);
    if (a == null) return null;
    final c = _clients[serverId];
    if (c != null && c.baseUrl == a.baseUrl && c.accessToken == a.token) return c;
    c?.close();
    return _clients[serverId] = JellyfinClient(
      baseUrl: a.baseUrl,
      clientInfo: clientInfo,
      accessToken: a.token,
      userId: a.userId,
      http: httpFactory?.call(),
    );
  }

  // ---------------------------------------------------------- validation

  Future<void> validateAll() => Future.wait([for (final a in _accounts) validate(a.serverId)]);

  /// Checks the saved token. Tries each known address in order and moves
  /// the first that answers to the front.
  Future<JellyfinAccountStatus> validate(String serverId) async {
    final start = account(serverId);
    if (start == null) return JellyfinAccountStatus.unknown;
    _status[serverId] = JellyfinAccountStatus.checking;
    _notify();
    Object? lastError;
    for (final url in start.urls) {
      final client = JellyfinClient(
        baseUrl: url,
        clientInfo: clientInfo,
        accessToken: start.token,
        userId: start.userId,
        http: httpFactory?.call(),
      );
      try {
        final user = await client.validateToken();
        if (user == null) return _setStatus(serverId, JellyfinAccountStatus.expired);
        final a = account(serverId);
        if (a == null) return JellyfinAccountStatus.unknown;
        _replace(a.copyWith(
          userName: user.name.isEmpty ? null : user.name,
          userImageTag: user.primaryImageTag,
          urls: [url, ...a.urls.where((u) => u != url)],
        ));
        unawaited(_save());
        _errors.remove(serverId);
        return _setStatus(serverId, JellyfinAccountStatus.online);
      } catch (e) {
        lastError = e;
      } finally {
        client.close();
      }
    }
    _errors[serverId] = _short(lastError);
    return _setStatus(serverId, JellyfinAccountStatus.offline);
  }

  static String _short(Object? e) {
    final s = '$e'.replaceFirst('JellyfinException: ', '');
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  JellyfinAccountStatus _setStatus(String serverId, JellyfinAccountStatus s) {
    _status[serverId] = s;
    _notify();
    return s;
  }

  /// A browse call got 401: the token is gone, ask to reconnect.
  void markExpired(String serverId) {
    if (statusOf(serverId) == JellyfinAccountStatus.expired) return;
    _setStatus(serverId, JellyfinAccountStatus.expired);
  }

  void _replace(JellyfinAccount a) {
    _accounts = [for (final o in _accounts) o.serverId == a.serverId ? a : o];
  }

  // ------------------------------------------------------- link / unlink

  /// Stores a sign-in made by this app. Signing in again to a linked server
  /// replaces its account (and best-effort revokes the old token).
  Future<JellyfinAccount> link({
    required String baseUrl,
    required JellyfinServerInfo server,
    required JellyfinAuthResult auth,
  }) async {
    await ensureLoaded(validate: false);
    final serverId = auth.serverId.isNotEmpty ? auth.serverId : server.id;
    final old = account(serverId);
    final a = JellyfinAccount(
      serverId: serverId,
      serverName: server.name,
      serverVersion: server.version,
      urls: [baseUrl, ...?old?.urls.where((u) => u != baseUrl)],
      userId: auth.user.id,
      userName: auth.user.name,
      userImageTag: auth.user.primaryImageTag,
      token: auth.accessToken,
    );
    if (old != null && old.token != a.token) unawaited(_revoke(old));
    _accounts = old == null ? [..._accounts, a] : [for (final o in _accounts) o.serverId == serverId ? a : o];
    _defaultServerId ??= serverId;
    _status[serverId] = JellyfinAccountStatus.online;
    _errors.remove(serverId);
    _clearMemo(serverId);
    await _save();
    _notify();
    return a;
  }

  Future<void> _revoke(JellyfinAccount a) async {
    final c = JellyfinClient(
        baseUrl: a.baseUrl,
        clientInfo: clientInfo,
        accessToken: a.token,
        userId: a.userId,
        http: httpFactory?.call());
    try {
      await c.logout();
    } catch (_) {
    } finally {
      c.close();
    }
  }

  /// Revokes the token on the server (best effort: an offline server or an
  /// already dead token still unlinks) and forgets the account.
  Future<void> signOut(String serverId) async {
    final a = account(serverId);
    if (a == null) return;
    final c = _clients.remove(serverId);
    c?.close();
    await _revoke(a).timeout(const Duration(seconds: 8), onTimeout: () {});
    _accounts = [for (final o in _accounts) if (o.serverId != serverId) o];
    _status.remove(serverId);
    _errors.remove(serverId);
    _clearMemo(serverId);
    if (_defaultServerId == serverId) _defaultServerId = _accounts.firstOrNull?.serverId;
    if (_lastPick?.serverId == serverId) await rememberPick(null);
    await _save();
    _notify();
  }

  Future<void> setDefault(String serverId) async {
    if (account(serverId) == null || _defaultServerId == serverId) return;
    _defaultServerId = serverId;
    _notify();
    await _save();
  }

  Future<void> rememberPick(JellyfinMedia? pick) async {
    _lastPick = pick;
    try {
      await _store.put(_keyLastPick, pick == null ? null : jsonEncode(pick.toJson()));
    } catch (e) {
      debugPrint('save jellyfin pick failed: $e');
    }
  }

  /// The browser's last location on [serverId] (encoded route stack, see
  /// `browse_scope.dart`), restored by every browser and across restarts.
  Object? browseLocation(String serverId) {
    try {
      final v = _store.get('$_keyBrowsePrefix$serverId');
      return v is String ? _tryJson(v) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveBrowseLocation(String serverId, Object? location) async {
    try {
      await _store.put(
          '$_keyBrowsePrefix$serverId', location == null ? null : jsonEncode(location));
    } catch (e) {
      debugPrint('save browse location failed: $e');
    }
  }

  /// Continue-row entries removed by hand on [serverId] (key -> when), so a
  /// next-up series (which Jellyfin cannot drop) stays out until it is
  /// played again. Keys are `continueKey`s.
  Map<String, DateTime> continueDismissed(String serverId) {
    try {
      final v = _store.get('$_keyDismissedPrefix$serverId');
      final j = v is String ? _tryJson(v) : null;
      if (j is! Map) return const {};
      return {
        for (final e in j.entries)
          if (e.key is String && e.value is int)
            e.key as String: DateTime.fromMillisecondsSinceEpoch(e.value as int, isUtc: true),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Keeps [key] out of the Continue row on [serverId] until it is played
  /// after [at] (default now). The newest 200 are kept.
  Future<void> dismissContinue(String serverId, String key, {DateTime? at}) async {
    final all = {...continueDismissed(serverId), key: (at ?? DateTime.now()).toUtc()};
    final newest = all.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    try {
      await _store.put('$_keyDismissedPrefix$serverId', jsonEncode({
        for (final e in newest.take(200)) e.key: e.value.millisecondsSinceEpoch,
      }));
    } catch (e) {
      debugPrint('save dismissed continue failed: $e');
    }
  }

  // --------------------------------------------------------------- cache

  /// Short-lived memo for browse calls, so going back does not refetch.
  /// Failures are not kept; a 401 marks the account expired.
  Future<T> cached<T>(String serverId, String key, Future<T> Function() load,
      {Duration ttl = const Duration(minutes: 3)}) {
    final k = '$serverId|$key';
    final hit = _memo[k];
    if (hit != null && DateTime.now().difference(hit.at) < ttl) {
      return hit.value.then((v) => v as T);
    }
    final f = load();
    _memo[k] = (at: DateTime.now(), value: f);
    f.catchError((Object e) {
      if (identical(_memo[k]?.value, f)) _memo.remove(k);
      if (e is JellyfinException && e.isUnauthorized) markExpired(serverId);
      throw e;
    }).ignore();
    return f;
  }

  void _clearMemo(String serverId) =>
      _memo.removeWhere((k, _) => k.startsWith('$serverId|'));

  /// Drops cached browse results (refresh button, after a pick).
  void invalidate(String serverId) => _clearMemo(serverId);

  final _watched = StreamController<String>.broadcast();

  /// Server ids whose watched state this app just changed (a stop report):
  /// their cached lists are gone, and browse views reload.
  Stream<String> get watched => _watched.stream;

  void watchedChanged(String serverId) {
    _clearMemo(serverId);
    _watched.add(serverId);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
    super.dispose();
  }
}
