import 'package:flutter/foundation.dart';

import '../../session/connection.dart' show connectErrorText;
import '../../session/identity.dart';
import '../../session/navigation.dart';
import '../../session/session_coordinator.dart';
import '../../state/connect_prefs.dart';
import '../../sync/sync_client.dart' show HelloRefused;
import 'health_probe.dart' show VersionGateRefused;

/// What the Join card shows under its fields after a failed attempt.
/// [offerUpdate]: this app is the older one (the version gate), so the
/// card offers the updater.
class CardError {
  final String title;
  final String message;
  final bool offerUpdate;
  const CardError(this.title, this.message, {this.offerUpdate = false});
}

/// The Join card's submit state, owned by the shell so an attempt and its
/// error outlive the card. One attempt at a time; [cancel] abandons it
/// ([Navigation.cancelPending]).
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({required this.navigation, required this.forms, this.profile});
  final Navigation navigation;
  final ConnectStore forms;
  /// Name and picture for the hello (default: the app's).
  final Profile? profile;

  bool busy = false;
  CardError? error;
  String? notice;
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

  void showError(CardError e) {
    error = e;
    notice = null;
    _notify();
  }

  void clearError() {
    if (error == null && notice == null) return;
    error = null;
    notice = null;
    _notify();
  }

  /// Validates and builds the params; throws [FormatException] with a
  /// user-facing message. [avatar] is the base64 picture (the profile's).
  static ConnectParams buildParams(ConnectForm f, {String avatar = ''}) {
    final port = int.tryParse(f.port.trim());
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    if (f.name.trim().isEmpty) {
      throw const FormatException('set your display name first (click your avatar at the top left)');
    }
    if (f.host.trim().isEmpty) {
      throw const FormatException('enter the server address');
    }
    return ConnectParams(host: f.host.trim(), port: port, secret: f.secret, name: f.name.trim(), avatar: avatar);
  }

  /// [edit] fills the card's fields into a copy of the form; the form is
  /// saved whatever happens (a failed join is when the user wants it back).
  Future<void> submit(void Function(ConnectForm f) edit) async {
    if (busy) return;
    final myAttempt = ++_attempt;
    final form = forms.form.copy();
    edit(form);
    form.name = form.name.trim();
    form.host = form.host.trim();
    busy = true;
    error = null;
    notice = null;
    _notify();

    ConnectParams params;
    try {
      final profile = this.profile ?? Profile.instance;
      await profile.ensureLoaded();
      params = buildParams(form, avatar: profile.avatarBase64());
    } catch (e) {
      if (myAttempt != _attempt) return;
      busy = false;
      error = CardError('Check the form', e is FormatException ? e.message : 'check the form and try again');
      _notify();
      return;
    }
    forms.form
      ..host = form.host
      ..port = form.port
      ..secret = form.secret;
    try {
      await navigation.join(params);
    } catch (e) {
      if (myAttempt != _attempt) return;
      busy = false;
      // In plain words: the version gate (who has to update), a refusal
      // (an older host, a wrong password, another window), offline.
      error = switch (e) {
        VersionGateRefused(:final message, :final youUpdate) =>
          CardError("Versions don't match", message, offerUpdate: youUpdate),
        HelloRefused() => CardError('Could not connect', connectErrorText(e)),
        _ => CardError('Could not connect', '$e'),
      };
      _notify();
      await forms.saveQuietly();
      return;
    }
    if (myAttempt != _attempt) {
      // Cancelled after it got through: back home.
      try {
        await navigation.goHome();
      } catch (_) {}
      return;
    }
    busy = false;
    _notify();
  }

  Future<void> cancel() async {
    final was = busy;
    _attempt++;
    try {
      await navigation.cancelPending();
    } catch (_) {}
    busy = false;
    if (was) notice = 'Cancelled';
    _notify();
  }
}
