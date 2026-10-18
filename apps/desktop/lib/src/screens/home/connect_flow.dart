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

/// Asks for a name before a join (the shell's "what do we call you?"
/// card, which saves it to [profile]): true to go on, false to drop the
/// join.
typedef AskName = Future<bool> Function(Profile profile);

/// The submit state of every join (the Join card, the join prompt for a
/// link or the clipboard), owned by the shell so an attempt and its
/// error outlive the card. One attempt at a time; [cancel] abandons it
/// ([Navigation.cancelPending]). Without a profile name a join first
/// asks for one ([askName]) and then goes on with it.
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({required this.navigation, required this.forms, this.profile, this.askName});
  final Navigation navigation;
  final ConnectStore forms;
  /// Name and picture for the hello (default: the app's).
  final Profile? profile;
  /// Without one, a join with no name takes [suggestedName].
  final AskName? askName;
  bool _asking = false;

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
  /// user-facing message. [avatar] is the base64 picture (the profile's);
  /// the name is the form's (the profile's: [submit] has one by then).
  static ConnectParams buildParams(ConnectForm f, {String avatar = ''}) {
    final port = int.tryParse(f.port.trim());
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    if (f.host.trim().isEmpty) {
      throw const FormatException('enter the server address');
    }
    return ConnectParams(host: f.host.trim(), port: port, secret: f.secret, name: f.name.trim(), avatar: avatar);
  }

  /// [edit] fills the card's fields into a copy of the form; the form is
  /// saved whatever happens (a failed join is when the user wants it back).
  Future<void> submit(void Function(ConnectForm f) edit) async {
    if (busy || _asking) return;
    final profile = this.profile ?? Profile.instance;
    if (!await _haveName(profile)) return;
    if (busy) return;
    final myAttempt = ++_attempt;
    final form = forms.form.copy();
    edit(form);
    form.name = profile.name.peek().trim();
    form.host = form.host.trim();
    busy = true;
    error = null;
    notice = null;
    _notify();

    ConnectParams params;
    try {
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

  /// The profile has a name, or gets one now: asked ([askName]; false
  /// when that was cancelled), else the suggestion.
  Future<bool> _haveName(Profile profile) async {
    _asking = true;
    try {
      await profile.ensureLoaded();
      if (profile.name.peek().trim().isNotEmpty) return true;
      final ask = askName;
      if (ask != null) return await ask(profile) && profile.name.peek().trim().isNotEmpty;
      final name = suggestedName();
      profile.setName(name.isEmpty ? 'Guest' : name);
      return true;
    } finally {
      _asking = false;
    }
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
