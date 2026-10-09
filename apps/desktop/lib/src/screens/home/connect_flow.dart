import 'package:flutter/foundation.dart';

import '../../session/session_coordinator.dart';
import '../../state/session_state.dart';
import 'profile.dart';

/// What a card shows under its fields after a failed attempt.
class CardError {
  final String title;
  final String message;
  const CardError(this.title, this.message);
}

/// Host/Join submit state for the strip's two connect cards. One attempt at a time;
/// [cancel] abandons it via [SessionState.cancelPending].
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({SessionState? session}) : _session = session ?? SessionState.instance;
  final SessionState _session;

  ConnectMode? busy;
  final errors = <ConnectMode, CardError?>{};
  final notices = <ConnectMode, String?>{};
  int _attempt = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void showError(ConnectMode mode, CardError error) {
    errors[mode] = error;
    notices[mode] = null;
    _notify();
  }

  void clearError(ConnectMode mode) {
    if (errors[mode] == null && notices[mode] == null) return;
    errors[mode] = null;
    notices[mode] = null;
    _notify();
  }

  /// Validates and builds the params; throws [FormatException] with a
  /// user-facing message. [avatar] is the base64 picture (the profile's).
  /// Hosting puts nothing up: what to watch is picked in the library.
  static ConnectParams buildParams(ConnectMode mode, ConnectForm f, {String avatar = ''}) {
    final rawPort = mode == ConnectMode.host ? f.hostPort : f.port;
    final port = int.tryParse(rawPort.trim());
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    if (f.name.trim().isEmpty) {
      throw const FormatException('set your display name first (click your avatar at the top left)');
    }
    if (mode == ConnectMode.join && f.host.trim().isEmpty) {
      throw const FormatException('enter the server address');
    }
    return ConnectParams(
      host: f.host.trim(),
      port: port,
      secret: mode == ConnectMode.host ? f.hostSecret : f.secret,
      name: f.name.trim(),
      avatar: avatar,
    );
  }

  /// [edit] fills the card's fields into a copy of the last form, so the
  /// other card's saved values survive.
  Future<void> submit(ConnectMode mode, void Function(ConnectForm f) edit) async {
    if (busy != null) return;
    final myAttempt = ++_attempt;
    final form = _session.lastForm.copy();
    edit(form);
    form.name = form.name.trim();
    form.host = form.host.trim();
    busy = mode;
    errors[mode] = null;
    notices[mode] = null;
    _notify();

    ConnectParams params;
    try {
      final profile = Profile.instance;
      await profile.ensureLoaded();
      params = buildParams(mode, form, avatar: profile.avatarBase64());
    } catch (e) {
      if (myAttempt != _attempt) return;
      busy = null;
      errors[mode] = CardError('Check the form',
          e is FormatException ? e.message : 'check the form and try again');
      _notify();
      return;
    }
    try {
      if (mode == ConnectMode.host) {
        await _session.host(params, form);
      } else {
        await _session.join(params, form);
      }
    } catch (e) {
      if (myAttempt != _attempt) return;
      busy = null;
      errors[mode] = CardError('Could not connect', '$e');
      _notify();
      return;
    }
    if (myAttempt != _attempt) {
      // Cancelled after it got through: back out.
      try {
        await _session.leave();
        await _session.stopServer();
      } catch (_) {}
      return;
    }
    busy = null;
    _notify();
    await _session.rememberServer(RecentServer(
      hosted: mode == ConnectMode.host,
      host: mode == ConnectMode.host ? '' : form.host,
      port: mode == ConnectMode.host ? form.hostPort.trim() : form.port.trim(),
      secret: mode == ConnectMode.host ? form.hostSecret : form.secret,
    ));
  }

  Future<void> cancel() async {
    final mode = busy;
    _attempt++;
    try {
      await _session.cancelPending();
    } catch (_) {}
    busy = null;
    if (mode != null) notices[mode] = 'Cancelled';
    _notify();
  }
}
