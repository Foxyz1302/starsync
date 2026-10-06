import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../session/session_coordinator.dart';
import '../../state/session_state.dart';
import '../../widgets/avatar_pipeline.dart';
import '../../widgets/media_input.dart';

/// What a card shows under its fields after a failed attempt.
class CardError {
  final String title;
  final String message;
  const CardError(this.title, this.message);
}

/// Host/Join submit state for the two Home cards. One attempt at a time;
/// [cancel] abandons it via [SessionState.cancelPending].
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({SessionState? session}) : _session = session ?? SessionState.instance;
  final SessionState _session;

  ConnectMode? busy;
  final errors = <ConnectMode, CardError?>{};
  final notices = <ConnectMode, String?>{};
  int _attempt = 0;
  bool _disposed = false;

  /// Set when an attempt ends in a kick, so Home shows the removal dialog.
  void Function(String reason)? onKicked;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError(ConnectMode mode) {
    if (errors[mode] == null && notices[mode] == null) return;
    errors[mode] = null;
    notices[mode] = null;
    _notify();
  }

  /// Validates and builds the params; throws [FormatException] with a
  /// user-facing message.
  static Future<ConnectParams> buildParams(ConnectMode mode, ConnectForm f) async {
    final rawPort = mode == ConnectMode.host ? f.hostPort : f.port;
    final port = int.tryParse(rawPort.trim());
    if (port == null || port <= 0 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    if (f.name.trim().isEmpty) {
      throw const FormatException('set your display name first (click your profile at the top)');
    }
    if (mode == ConnectMode.join && f.host.trim().isEmpty) {
      throw const FormatException('enter the server address');
    }
    String avatar = '';
    try {
      avatar = await encodeAvatar(f.avatarPath);
    } on FormatException catch (e) {
      throw FormatException(e.message);
    } catch (_) {
      throw const FormatException('could not process that avatar — pick a PNG, JPG or WebP photo');
    }
    if (mode == ConnectMode.host &&
        f.mediaPath.isNotEmpty &&
        !await File(f.mediaPath).exists()) {
      throw const FormatException('media file not found — check the path or pick again with Browse');
    }
    return ConnectParams(
      host: f.host.trim(),
      port: port,
      secret: mode == ConnectMode.host ? f.hostSecret : f.secret,
      name: f.name.trim(),
      avatar: avatar,
      mediaPath: mode == ConnectMode.host ? f.mediaPath : '',
      linkUrl: mode == ConnectMode.host ? f.linkUrl : '',
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
    if (mode == ConnectMode.host) {
      final parsed = parseMediaInput(form.linkUrl.isNotEmpty ? form.linkUrl : form.mediaPath);
      form
        ..mediaPath = parsed.mediaPath
        ..linkUrl = parsed.linkUrl;
    }
    busy = mode;
    errors[mode] = null;
    notices[mode] = null;
    _notify();

    final ConnectParams params;
    try {
      params = await buildParams(mode, form);
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
      final kick = _session.coordinator.kickReason.peek();
      if (kick != null && kick.isNotEmpty) {
        onKicked?.call(kick);
      } else {
        errors[mode] = CardError('Could not connect', '$e');
      }
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
