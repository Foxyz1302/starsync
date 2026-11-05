import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'distribution.dart';
import 'logging.dart';
import 'signing.dart';

// The signed config (ARCHITECTURE "Updater", Config): Starsync's own
// addresses, so any of them can move without a reinstall. The repo copy is
// `updates/starsync-config.json`, signed by `dart tool/sign_config.dart`.
//
//   {"schema": 1, "serial": 3,
//    "configUrls": ["https://.../starsync-config.json", ...],
//    "updates": {"stable": ["https://.../manifest.json", ...],
//                "dev": ["https://.../manifest.json", ...]},
//    "nextKey": "<base64 public key>"}            (optional)
//
// The app takes the first copy, in the order of [RemoteConfigSource.candidates],
// whose signature is good and whose serial is above the one it has, and
// keeps it in its data folder; it uses the saved copy while every fetch
// fails and the built-in values (distribution.dart) without one.

final _log = createLogger('config');

/// The config's file name, in the repo (`updates/`), on every host and in
/// the data folder; its signature is `starsync-config.json.sig`.
const configFileName = 'starsync-config.json';

/// The keys taken over from configs' `nextKey` (data folder), when they
/// differ from distribution.dart's.
const configKeysFileName = 'starsync-keys.json';

bool _isWebUrl(String s) {
  final u = Uri.tryParse(s.trim());
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}

class RemoteConfig {
  /// The schema this build reads; a config with another one is refused.
  static const schema = 1;

  /// Rises with every published change; a copy counts only when it is
  /// above the one the app has (built-in: 0).
  final int serial;
  /// Where to look for the config next time (before the built-in list).
  final List<String> configUrls;
  /// The releases' manifest addresses, tried in order.
  final List<String> stable;
  /// The test builds' manifest addresses, tried in order.
  final List<String> dev;
  /// A public key to trust from now on (key handover), signed in by the
  /// current one.
  final String? nextKey;

  const RemoteConfig(
      {required this.serial, required this.configUrls, required this.stable, required this.dev, this.nextKey});

  /// distribution.dart's values: what a build without a saved copy uses
  /// (the built-in config addresses are [RemoteConfigSource.builtInUrls]).
  static const builtIn =
      RemoteConfig(serial: 0, configUrls: [], stable: builtInStableManifestUrls, dev: builtInDevManifestUrls);

  /// Throws a [FormatException] for anything but a schema-1 config with a
  /// positive serial and at least one stable and one dev address.
  /// Addresses that are not http(s) URLs are dropped.
  factory RemoteConfig.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('config is not a JSON object');
    if (json['schema'] != schema) {
      throw FormatException('config schema ${json['schema']}, this build reads $schema');
    }
    final serial = json['serial'];
    if (serial is! int || serial < 1) throw const FormatException('config serial is not a positive integer');
    List<String> urls(Object? v, String what, {bool required = true}) {
      final out = [
        if (v is List)
          for (final s in v)
            if (s is String && _isWebUrl(s)) s.trim(),
      ];
      if (required && out.isEmpty) throw FormatException('config has no $what addresses');
      return List.unmodifiable(out);
    }

    final updates = json['updates'];
    if (updates is! Map) throw const FormatException('config has no updates');
    final nextKey = json['nextKey'];
    if (nextKey != null && (nextKey is! String || decodePublicKey(nextKey) == null)) {
      throw const FormatException('config nextKey is not a public key');
    }
    return RemoteConfig(
      serial: serial,
      configUrls: urls(json['configUrls'], 'config', required: false),
      stable: urls(updates['stable'], 'stable'),
      dev: urls(updates['dev'], 'dev'),
      nextKey: (nextKey as String?)?.trim(),
    );
  }
}

/// The config this app goes by and the keys it trusts: loaded from the
/// data folder ([dir]; none: built-in values only, as for `--upgrade`)
/// and refreshed from the hosts ([refresh], with each update check).
class RemoteConfigSource {
  /// The data folder the accepted copy is kept in; null keeps nothing.
  final String? dir;
  /// Settings → Updates → More, "Config address": tried first.
  final String? Function()? extraUrl;
  final List<String> builtInKeys;
  final List<String> builtInUrls;
  final RemoteConfig builtIn;
  final Duration timeout;

  RemoteConfigSource(
      {this.dir,
      this.extraUrl,
      this.builtInKeys = trustedKeys,
      this.builtInUrls = builtInConfigUrls,
      this.builtIn = RemoteConfig.builtIn,
      this.timeout = const Duration(seconds: 10)})
      : _current = builtIn,
        _keys = List.unmodifiable(builtInKeys);

  RemoteConfig _current;
  List<String> _keys;
  Future<void>? _loaded;
  Future<RemoteConfig>? _refreshing;

  /// The saved copy (once [load]ed) or the newest accepted one; else
  /// [builtIn].
  RemoteConfig get current => _current;

  /// The public keys signatures are checked against, oldest first:
  /// [builtInKeys], plus the keys handed over by configs (an older key
  /// is dropped once a config signed by a handed-over newer one arrives).
  List<String> get keys => _keys;

  /// Where [refresh] looks, in order: the config address setting, the
  /// current copy's `configUrls`, the built-in list (each once).
  List<String> get candidates {
    final extra = extraUrl?.call()?.trim() ?? '';
    final seen = <String>{};
    return [
      for (final u in [if (_isWebUrl(extra)) extra, ..._current.configUrls, ...builtInUrls])
        if (seen.add(u)) u,
    ];
  }

  /// Reads the saved copy once; a copy whose signature is not good is
  /// ignored (and logged).
  Future<void> load() => _loaded ??= _load();

  Future<void> _load() async {
    final d = dir;
    if (d == null) return;
    try {
      final keysFile = File('$d/$configKeysFileName');
      if (await keysFile.exists()) {
        final list = jsonDecode(await keysFile.readAsString());
        final keys = [
          if (list is List)
            for (final k in list)
              if (k is String && decodePublicKey(k) != null) k,
        ];
        if (keys.isNotEmpty) _keys = List.unmodifiable(keys);
      }
    } catch (e) {
      _log.warning('saved keys ignored: $e');
    }
    final file = File('$d/$configFileName');
    final sigFile = File('$d/$configFileName.sig');
    try {
      if (!await file.exists() || !await sigFile.exists()) return;
      final bytes = await file.readAsBytes();
      if (await verifyDetached(bytes, await sigFile.readAsString(), _keys) == null) {
        _log.warning('saved config ignored: its signature is not good');
        return;
      }
      final c = RemoteConfig.fromJson(jsonDecode(utf8.decode(bytes)));
      if (c.serial > _current.serial) _current = c;
      _log.info('saved config serial ${c.serial}');
    } catch (e) {
      _log.warning('saved config ignored: $e');
    }
  }

  /// Looks for a newer copy ([candidates], in order) and takes the first
  /// one whose signature is good and whose serial is above [current]'s;
  /// never throws. Calls while one runs join it.
  Future<RemoteConfig> refresh({HttpClient? http}) =>
      _refreshing ??= _refresh(http).whenComplete(() => _refreshing = null);

  Future<RemoteConfig> _refresh(HttpClient? http) async {
    await load();
    final client = http ?? HttpClient();
    try {
      for (final url in candidates) {
        try {
          final got = await fetchSigned(client, url, timeout: timeout, maxBytes: 64 * 1024);
          if (await accept(got.body, got.sig, from: url)) break;
        } catch (e) {
          _log.fine('config $url: ${e is UpdateRefused ? e.detail : e}');
        }
      }
    } finally {
      if (http == null) client.close();
    }
    return _current;
  }

  /// Takes [body] (signed by [sig]) as the config when its signature is
  /// good and its serial newer: true when taken. Throws an [UpdateRefused]
  /// for a bad or missing signature, a [FormatException] for a malformed
  /// config; an older or the same serial is false.
  Future<bool> accept(List<int> body, String? sig, {String from = 'config'}) async {
    final signer = sig == null ? null : await verifyDetached(body, sig, _keys);
    if (signer == null) {
      _log.warning('config from $from refused: ${sig == null ? 'not signed' : 'signature not good'}');
      throw UpdateRefused('The config is not signed by Starsync\'s developer',
          '$from: ${sig == null ? 'no signature' : 'signature not good'}');
    }
    final c = RemoteConfig.fromJson(jsonDecode(utf8.decode(body)));
    if (c.serial <= _current.serial) {
      _log.fine('config $from: serial ${c.serial}, have ${_current.serial}');
      return false;
    }
    // A config signed by a handed-over key retires the keys before it.
    var keys = builtInKeys.contains(_keys[signer]) ? _keys : _keys.sublist(signer);
    final next = c.nextKey;
    if (next != null && !keys.contains(next)) keys = [...keys, next];
    await _save(body, sig!, keys);
    _current = c;
    if (!_sameList(keys, _keys)) _log.info('signing keys now: ${keys.length} (handover)');
    _keys = List.unmodifiable(keys);
    _log.info('config serial ${c.serial} from $from');
    return true;
  }

  Future<void> _save(List<int> body, String sig, List<String> keys) async {
    final d = dir;
    if (d == null) return;
    try {
      await Directory(d).create(recursive: true);
      final keysFile = File('$d/$configKeysFileName');
      if (_sameList(keys, builtInKeys)) {
        if (await keysFile.exists()) await keysFile.delete();
      } else {
        await _writeAtomically(keysFile, utf8.encode(jsonEncode(keys)));
      }
      await _writeAtomically(File('$d/$configFileName.sig'), utf8.encode(sig));
      await _writeAtomically(File('$d/$configFileName'), body);
    } catch (e) {
      _log.warning('saving the config: $e');
    }
  }
}

bool _sameList(List<String> a, List<String> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

Future<void> _writeAtomically(File f, List<int> bytes) async {
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(f.path);
}
