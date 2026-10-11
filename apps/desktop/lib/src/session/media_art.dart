import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:sync_relay_core/core.dart';

import '../files/name_parser.dart';
import '../schedule/anilist.dart';

// Art for media this client swapped in (`art`, see PROTOCOL.md "Media
// art"): Jellyfin images with this install's account, a web link's
// thumbnail, else an AniList title search. Everything here fails quietly
// to "no art".

/// Poster and banner bytes; either may be null.
typedef ArtBytes = ({Uint8List? poster, Uint8List? banner});

/// Series poster (the item's own for movies) and series/item backdrop,
/// else its Banner image, scaled by Jellyfin to fit the caps.
Future<ArtBytes> jellyfinArt(JellyfinClient client, String itemId,
    {Future<Uint8List?> Function(Uri url, Map<String, String> headers, int maxBytes) fetch = fetchImage}) async {
  final item = await client.item(itemId).timeout(const Duration(seconds: 10));
  final seriesPoster = item.seriesId != null && item.seriesPrimaryImageTag != null
      ? JellyfinImageRef(item.seriesId!, JellyfinImageType.primary, item.seriesPrimaryImageTag!)
      : null;
  final poster = seriesPoster ?? item.image(JellyfinImageType.primary);
  var banner = item.image(JellyfinImageType.backdrop);
  if (banner == null) {
    var owner = item;
    if (item.seriesId != null && item.ownImage(JellyfinImageType.banner) == null) {
      try {
        owner = await client.item(item.seriesId!).timeout(const Duration(seconds: 10));
      } catch (_) {}
    }
    banner = owner.ownImage(JellyfinImageType.banner);
  }
  final headers = client.authHeaders;
  final (p, b) = await (
    poster == null
        ? Future<Uint8List?>.value()
        : fetch(client.imageUrl(poster, maxHeight: 450, quality: 85), headers, RelayConstants.maxPosterBytes),
    banner == null
        ? Future<Uint8List?>.value()
        : fetch(client.imageUrl(banner, maxWidth: 1280, quality: 85), headers, RelayConstants.maxBannerBytes),
  ).wait;
  return (poster: p, banner: b);
}

/// The series of release name [name] on AniList: cover and banner; null
/// when the name says nothing or AniList knows no match.
Future<ArtBytes?> aniListArt(AniListClient aniList, String name,
    {Future<Uint8List?> Function(Uri url, Map<String, String> headers, int maxBytes) fetch = fetchImage}) async {
  final series = parseReleaseName(name).series.trim();
  // "1", "2026-10-09": nothing a show could be called.
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(series)) return null;
  final match = await aniList.searchMedia(series);
  if (match == null) return null;
  Future<Uint8List?> get(String? url, int maxBytes) async {
    final uri = url == null ? null : Uri.tryParse(url);
    return uri == null ? null : fetch(uri, const {}, maxBytes);
  }

  final (cover, banner) = await (
    get(match.cover, RelayConstants.maxPosterBytes),
    get(match.banner, RelayConstants.maxBannerBytes),
  ).wait;
  final poster = cover ?? (match.coverSmall == match.cover ? null : await get(match.coverSmall, RelayConstants.maxPosterBytes));
  return (poster: poster, banner: banner);
}

/// A web video's thumbnail at [url] as both cover and banner (the same
/// bytes, so the same hash: what tells clients it is a thumbnail, see
/// `NowPlaying.thumbnail`); shrunk to a JPEG under the cover cap when
/// larger; null when it cannot be had.
Future<ArtBytes?> thumbnailArt(Uri url,
    {Future<Uint8List?> Function(Uri url, Map<String, String> headers, int maxBytes) fetch = fetchImage}) async {
  var bytes = await fetch(url, const {}, 8 * 1024 * 1024);
  if (bytes != null && bytes.length > RelayConstants.maxPosterBytes) bytes = await _shrinkApart(bytes);
  return bytes == null ? null : (poster: bytes, banner: bytes);
}

// Its own function, so the isolate's closure holds nothing but [raw].
Future<Uint8List?> _shrinkApart(Uint8List raw) => Isolate.run<Uint8List?>(() => _shrinkThumbnail(raw));

Uint8List? _shrinkThumbnail(Uint8List raw) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) return null;
  for (final width in const [1280, 960, 640]) {
    final small = decoded.width > width ? img.copyResize(decoded, width: width, interpolation: img.Interpolation.average) : decoded;
    final jpg = img.encodeJpg(small, quality: 82);
    if (jpg.length <= RelayConstants.maxPosterBytes) return jpg;
  }
  return null;
}

/// GET [url]: the bytes when 200, at most [maxBytes] and a known image
/// type (see `avatarImageType`); else null.
Future<Uint8List?> fetchImage(Uri url, Map<String, String> headers, int maxBytes) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200 || resp.contentLength > maxBytes) {
      await resp.drain<void>().catchError((_) {});
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 15))) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    final bytes = builder.takeBytes();
    return avatarImageType(bytes) == null ? null : bytes;
  } catch (e) {
    debugPrint('art: fetch failed: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}
