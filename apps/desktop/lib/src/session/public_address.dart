import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'invite.dart' show isPublicIpv4;

/// Fetches a URL's body as text; injectable so tests fake the services.
typedef TextGet = Future<String> Function(Uri uri);

/// "What is my IP" services, asked in order until one answers with a
/// public IPv4 address: each answers the plain address over HTTPS.
final publicAddressServices = [
  Uri.parse('https://api.ipify.org'),
  Uri.parse('https://ipv4.icanhazip.com'),
  Uri.parse('https://checkip.amazonaws.com'),
  Uri.parse('https://ifconfig.me/ip'),
];

const _eachTimeout = Duration(seconds: 3);

/// This network's internet (IPv4) address as the [services] see it: the
/// first that answers with a public address wins; a failing, slow or odd
/// one is skipped. Null when none does (offline, all blocked).
Future<String?> lookUpPublicAddress({
  TextGet get = defaultTextGet,
  List<Uri>? services,
  Duration each = _eachTimeout,
}) async {
  for (final uri in services ?? publicAddressServices) {
    try {
      final body = (await get(uri).timeout(each)).trim();
      // Some answer "ip\n", a few with a label: take the first word.
      final ip = body.split(RegExp(r'\s+')).first;
      if (isPublicIpv4(ip)) return ip;
      debugPrint('public address: ${uri.host} gave no public IPv4 address');
    } catch (e) {
      debugPrint('public address: ${uri.host} failed: ${e.runtimeType}');
    }
  }
  return null;
}

/// Plain dart:io GET of a small text body; non-200 throws.
Future<String> defaultTextGet(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = _eachTimeout
    ..userAgent = 'Starsync';
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(_eachTimeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('status ${res.statusCode}', uri: uri);
    }
    final body = StringBuffer();
    await for (final chunk in res.transform(utf8.decoder).timeout(_eachTimeout)) {
      body.write(chunk);
      if (body.length > 256) break; // an address, not a page
    }
    return body.toString();
  } finally {
    client.close(force: true);
  }
}
