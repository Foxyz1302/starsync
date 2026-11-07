import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show cleanMemberColor, validClientId;

import '../state/connect_prefs.dart';
import '../state/settings.dart' show settingsBoxName;
import '../widgets/avatar_pipeline.dart';

// Who this app is: to the server (the per-install client id and its
// rising connection count, [ClientIdentity]) and to people (name, picture
// and colour, [Profile]).

/// `hello.client` and `hello.seq` (PROTOCOL.md "Presence"): a random id
/// per install, kept in the settings box (so per data folder, and per
/// `STARSYNC_PROFILE`), and a number that rises with every connection this
/// install makes. A server maps the id to one lasting member; the higher
/// `seq` wins when two windows of the same install connect.
class ClientIdentity {
  static const _keyClient = 'clientId';
  static const _keySeq = 'clientSeq';

  final Box? _box;
  ClientIdentity._(this._box, this.clientId, this._seq);

  /// The id: 22 characters of base64url (16 random bytes). Private: never
  /// shown, never logged.
  final String clientId;
  int _seq;

  /// The last `seq` handed out.
  int get seq => _seq;

  /// The stored identity (the settings box, once open); one is made and
  /// stored on first use. Without the box (tests, no store): [ephemeral].
  factory ClientIdentity.stored() {
    final box = Hive.isBoxOpen(settingsBoxName) ? Hive.box(settingsBoxName) : null;
    if (box == null) return ClientIdentity.ephemeral();
    var id = box.get(_keyClient);
    if (id is! String || !validClientId(id)) {
      id = newClientId();
      unawaited(_put(box, _keyClient, id));
    }
    final seq = box.get(_keySeq);
    return ClientIdentity._(box, id, seq is int && seq > 0 ? seq : 0);
  }

  /// A fresh id kept in memory only (each test coordinator is its own
  /// install).
  factory ClientIdentity.ephemeral() => ClientIdentity._(null, newClientId(), 0);

  /// The `seq` for the next hello: one higher than any before, stored at
  /// once.
  int nextSeq() {
    _seq++;
    final box = _box;
    if (box != null) unawaited(_put(box, _keySeq, _seq));
    return _seq;
  }

  static Future<void> _put(Box box, String key, Object value) async {
    try {
      await box.put(key, value);
    } catch (e) {
      debugPrint('save $key failed: $e');
    }
  }

  /// 16 random bytes as 22 characters of base64url.
  static String newClientId() {
    final r = Random.secure();
    return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', '');
  }
}

/// Colours offered in the profile card; the first is the default.
const profileColors = <Color>[
  Colors.deepPurple,
  Colors.indigo,
  Colors.teal,
  Colors.pink,
  Colors.orange,
  Colors.blueGrey,
];

/// [c] as sent in hello and profile updates: `#rrggbb` (no alpha).
String colorToWire(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// A member's colour from the wire (`members[].color`); null when it has
/// none or it is not `#rrggbb`.
Color? colorFromWire(String wire) {
  final c = cleanMemberColor(wire);
  return c.isEmpty ? null : Color(0xFF000000 | int.parse(c.substring(1), radix: 16));
}

/// A name to offer someone who has none yet: the computer's user name
/// (`USER`, `USERNAME` on Windows), first letter capitalised; '' when
/// there is none. [env] stands in for the environment in tests.
String suggestedName([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  final raw = (e['USER'] ?? e['USERNAME'] ?? '').trim();
  if (raw.isEmpty || raw == 'root') return '';
  final name = raw.length > 32 ? raw.substring(0, 32) : raw;
  return name[0].toUpperCase() + name.substring(1);
}

const _keyPicture = 'avatarPng';
const _keyColor = 'profileColor';

/// Sends a mid-session name/picture/colour change (null = unchanged,
/// empty avatar = removed, colour as `#rrggbb`). Swappable so tests can
/// watch it.
typedef ProfilePush = void Function({String? name, String? avatar, String? color});

/// Display name, picture and colour of this app's user. Backed by the
/// connect form ([forms]: the name) and the connect-form box (the cropped
/// 256 px PNG and the colour); every change is persisted, and while in a
/// server it is pushed through [push] so everyone sees it at once. The
/// composition root sets both.
class Profile {
  static final Profile instance = Profile._();
  Profile._();

  final name = signal('');
  /// The cropped PNG; null shows the initial on [color].
  final picture = signal<Uint8List?>(null);
  final color = signal<Color>(profileColors.first);
  final error = signal<String?>(null);
  ProfilePush push = ({String? name, String? avatar, String? color}) {};
  ConnectStore forms = ConnectStore();
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
    final form = forms.form;
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

  /// The colour as sent in hello and profile updates (`#rrggbb`).
  String colorWire() => colorToWire(color.peek());

  void setName(String value) {
    final v = value.trim();
    if (v.isEmpty || v == name.peek()) return;
    name.value = v;
    forms.form.name = v;
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
    push(color: colorToWire(c));
    await _save();
  }

  Future<void> _save() async {
    try {
      await forms.save();
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
