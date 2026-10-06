import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';

enum JellyfinSignInStep {
  /// Typing the server address.
  address,
  probing,
  /// Server found: choose Quick Connect or password.
  method,
  /// Code shown, polling until the user approves it in Jellyfin.
  quickConnect,
  password,
  signingIn,
  /// Linked; [JellyfinSignIn.linked] is the account.
  done,
}

/// Add-server / reconnect flow: address -> /System/Info/Public -> Quick
/// Connect (code + poll, cancellable) or username/password -> linked in
/// [JellyfinAccounts]. UI-free so tests drive it with a fake transport.
class JellyfinSignIn extends ChangeNotifier {
  JellyfinSignIn(this.accounts, {this.pollInterval = const Duration(seconds: 3), this.reconnect});

  final JellyfinAccounts accounts;
  final Duration pollInterval;
  /// Set when re-signing an expired account: the address is prefilled.
  final JellyfinAccount? reconnect;

  JellyfinSignInStep _step = JellyfinSignInStep.address;
  String? _error;
  JellyfinServerInfo? _server;
  bool _quickConnectAvailable = false;
  String? _code;
  JellyfinAccount? _linked;
  JellyfinClient? _client;
  int _gen = 0;
  bool _disposed = false;

  JellyfinSignInStep get step => _step;
  String? get error => _error;
  JellyfinServerInfo? get server => _server;
  String? get baseUrl => _client?.baseUrl;
  bool get quickConnectAvailable => _quickConnectAvailable;
  /// The Quick Connect code to show.
  String? get code => _code;
  JellyfinAccount? get linked => _linked;
  bool get busy =>
      _step == JellyfinSignInStep.probing || _step == JellyfinSignInStep.signingIn;

  void _set(JellyfinSignInStep s, {String? error}) {
    _step = s;
    _error = error;
    if (!_disposed) notifyListeners();
  }

  /// Checks [input] is a Jellyfin server and whether Quick Connect is on.
  Future<void> probe(String input) async {
    final url = normalizeServerUrl(input);
    if (url == null) {
      _set(JellyfinSignInStep.address, error: 'Enter the server address, e.g. jellyfin.example.com');
      return;
    }
    final gen = ++_gen;
    _client?.close();
    final client = _client = accounts.anonymousClient(url);
    _set(JellyfinSignInStep.probing);
    try {
      final info = await client.publicInfo();
      if (gen != _gen) return;
      if (info.id.isEmpty) throw const JellyfinException('not a Jellyfin server');
      if (reconnect != null && info.id != reconnect!.serverId) {
        _set(JellyfinSignInStep.address,
            error: 'That address is a different Jellyfin server (${info.name}).');
        return;
      }
      var qc = false;
      try {
        qc = await client.quickConnectEnabled();
      } catch (_) {}
      if (gen != _gen) return;
      _server = info;
      _quickConnectAvailable = qc;
      _set(JellyfinSignInStep.method);
    } catch (e) {
      if (gen != _gen) return;
      _set(JellyfinSignInStep.address, error: 'No Jellyfin server at $url (${_short(e)})');
    }
  }

  /// Starts Quick Connect: shows the code, polls until approved, links.
  Future<void> startQuickConnect() async {
    final client = _client;
    if (client == null || _server == null) return;
    final gen = ++_gen;
    _code = null;
    _set(JellyfinSignInStep.quickConnect);
    try {
      final session = await client.quickConnectInitiate();
      if (gen != _gen) return;
      _code = session.code;
      _set(JellyfinSignInStep.quickConnect);
      final auth = await client.waitForQuickConnect(session,
          interval: pollInterval, isCancelled: () => gen != _gen || _disposed);
      if (auth == null || gen != _gen) return;
      await _finish(auth);
    } on TimeoutException {
      if (gen == _gen) _set(JellyfinSignInStep.method, error: 'The code expired. Try again.');
    } catch (e) {
      if (gen != _gen) return;
      final msg = e is JellyfinException && e.isUnauthorized
          ? 'Quick Connect is turned off on this server. Use your password.'
          : e is JellyfinException && e.statusCode == 404
              ? 'The code expired. Try again.'
              : 'Quick Connect failed: ${_short(e)}';
      _set(JellyfinSignInStep.method, error: msg);
    }
  }

  /// Stops waiting for the Quick Connect code.
  void cancel() {
    _gen++;
    _code = null;
    _set(_server == null ? JellyfinSignInStep.address : JellyfinSignInStep.method);
  }

  void usePassword() => _set(JellyfinSignInStep.password);

  /// Back to the address field.
  void changeAddress() {
    _gen++;
    _server = null;
    _code = null;
    _set(JellyfinSignInStep.address);
  }

  Future<void> signIn(String username, String password) async {
    final client = _client;
    if (client == null) return;
    if (username.trim().isEmpty) {
      _set(JellyfinSignInStep.password, error: 'Enter your Jellyfin username');
      return;
    }
    final gen = ++_gen;
    _set(JellyfinSignInStep.signingIn);
    try {
      final auth = await client.authenticateByName(username.trim(), password);
      if (gen != _gen) return;
      await _finish(auth);
    } catch (e) {
      if (gen != _gen) return;
      _set(JellyfinSignInStep.password,
          error: e is JellyfinException && e.isUnauthorized
              ? 'Wrong username or password'
              : 'Sign-in failed: ${_short(e)}');
    }
  }

  Future<void> _finish(JellyfinAuthResult auth) async {
    final server = _server!;
    if (auth.accessToken.isEmpty) throw const JellyfinException('no token in the answer');
    _linked = await accounts.link(baseUrl: _client!.baseUrl, server: server, auth: auth);
    _code = null;
    _set(JellyfinSignInStep.done);
  }

  static String _short(Object e) {
    final s = '$e'.replaceFirst(RegExp(r'^JellyfinException( \d+)?: '), '');
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _client?.close();
    super.dispose();
  }
}
