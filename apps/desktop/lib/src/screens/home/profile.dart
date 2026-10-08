import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/connect_prefs.dart';
import '../../state/session_state.dart';
import '../../widgets/avatar_pipeline.dart';

/// Colours offered in the profile card; the first is the default.
const profileColors = <Color>[
  Colors.deepPurple,
  Colors.indigo,
  Colors.teal,
  Colors.pink,
  Colors.orange,
  Colors.blueGrey,
];

const _keyPicture = 'avatarPng';
const _keyColor = 'profileColor';

/// Sends a mid-session name/picture change (null = unchanged, empty
/// avatar = removed). Swappable so tests can watch it.
typedef ProfilePush = void Function({String? name, String? avatar});

/// The one place a profile change reaches the server.
void pushProfileToSession({String? name, String? avatar}) {
  final session = SessionState.instance;
  if (session.route.peek() != AppRoute.session) return;
  session.coordinator.updateProfile(name: name, avatar: avatar);
}

/// Display name, picture and colour of this app's user. Backed by
/// [SessionState.lastForm] (name) and the connect-form box (the cropped
/// 256 px PNG and the colour); every change is persisted, and while in a
/// server it is pushed through [push] so everyone sees it at once.
class Profile {
  static final Profile instance = Profile._();
  Profile._();

  final name = signal('');
  /// The cropped PNG; null shows the initial on [color].
  final picture = signal<Uint8List?>(null);
  final color = signal<Color>(profileColors.first);
  final error = signal<String?>(null);
  ProfilePush push = pushProfileToSession;
  bool _loaded = false;
  Timer? _nameTimer;

  /// Reads the stored profile once (the app shell starts it). Old installs
  /// stored a picture path: it is shrunk through [encodeAvatar] once and
  /// kept as bytes. A caller during the first read does not wait for it
  /// (no shared Future: tests run each in its own zone).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    await _load();
  }

  Future<void> _load() async {
    final form = SessionState.instance.lastForm;
    name.value = form.name;
    try {
      final box = connectFormBoxIfOpen() ?? await openConnectFormBox();
      final png = box.get(_keyPicture);
      final c = box.get(_keyColor);
      if (c is int) color.value = Color(c);
      if (png is Uint8List && png.isNotEmpty) {
        picture.value = png;
      } else if (form.avatarPath.isNotEmpty) {
        final b64 = await encodeAvatar(form.avatarPath);
        if (b64.isNotEmpty) picture.value = base64Decode(b64);
        form.avatarPath = '';
        await _save();
      }
    } catch (e) {
      // No store (tests) or an unreadable old picture: start without.
      debugPrint('profile load: $e');
    }
  }

  /// The picture as sent in hello and profile updates; '' when none.
  String avatarBase64() {
    final png = picture.peek();
    return png == null ? '' : avatarWireBase64(png);
  }

  void setName(String value) {
    final v = value.trim();
    if (v.isEmpty || v == name.peek()) return;
    name.value = v;
    SessionState.instance.lastForm.name = v;
    unawaited(_save());
    // Typing renames once it settles, not on every key.
    _nameTimer?.cancel();
    _nameTimer = Timer(const Duration(milliseconds: 600), () => push(name: name.peek()));
  }

  Future<void> setPicture(Uint8List? png) async {
    picture.value = png;
    error.value = null;
    await _save();
    try {
      push(avatar: png == null ? '' : avatarWireBase64(png));
    } on FormatException catch (e) {
      error.value = e.message;
    }
  }

  Future<void> setColor(Color c) async {
    color.value = c;
    await _save();
  }

  Future<void> _save() async {
    try {
      await SessionState.instance.saveForm();
      final box = connectFormBoxIfOpen() ?? await openConnectFormBox();
      final png = picture.peek();
      await box.putAll({
        _keyPicture: png ?? Uint8List(0),
        _keyColor: color.peek().toARGB32(),
      });
    } catch (_) {
      error.value = 'could not save profile — try again';
    }
  }
}
