import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'relay.dart';
import 'yt_dlp.dart';

// What a pasted link is: a media file (range-readable as is) or a web page
// that yt-dlp turns into one. Used where the bytes are fetched: the
// putter's app (preview, "I pass it on") and the server ("the server
// fetches it").

const _mediaExtensions = {
  'mkv', 'mp4', 'm4v', 'webm', 'mov', 'avi', 'wmv', 'flv', 'ts', 'm2ts', 'mpg', 'mpeg', 'ogv', //
  'mp3', 'm4a', 'flac', 'opus', 'ogg', 'wav',
};

const _fileTypes = {'application/mp4', 'application/ogg', 'application/x-matroska'};
const _genericTypes = {'', 'application/octet-stream', 'binary/octet-stream', 'application/binary'};

/// True when a `Range: bytes=0-0` answer ([status], [contentType]'s mime
/// type) means [url] is a media file: a video/audio type, or a generic one
/// on a media file name. Pages, HLS playlists and errors are not.
bool looksLikeMediaFile({required int status, required String contentType, required Uri url}) {
  if (status != 200 && status != 206) return false;
  final type = contentType.toLowerCase();
  if (type.contains('mpegurl')) return false;
  if (type.startsWith('video/') || type.startsWith('audio/') || _fileTypes.contains(type)) return true;
  return _genericTypes.contains(type) && hasMediaExtension(url);
}

/// [url]'s file name ends in a media extension (`.mkv`, `.mp4`, ...).
bool hasMediaExtension(Uri url) {
  final last = url.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
  final dot = last.lastIndexOf('.');
  return dot > 0 && _mediaExtensions.contains(last.substring(dot + 1).toLowerCase());
}

/// A page's `og:title`, else its `<title>`, entities decoded; null if
/// neither.
String? htmlTitle(String html) {
  for (final tag in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final t = tag.group(0)!;
    if (!RegExp(r'''(?:property|name)\s*=\s*["']og:title["']''', caseSensitive: false).hasMatch(t)) continue;
    final c = RegExp('content\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', caseSensitive: false).firstMatch(t);
    final v = _unescape(c?.group(1) ?? c?.group(2) ?? '');
    if (v.isNotEmpty) return v;
  }
  final m = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html);
  final v = _unescape(m?.group(1) ?? '');
  return v.isEmpty ? null : v;
}

String _unescape(String s) => s
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
      final n = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
      return n == null ? m.group(0)! : String.fromCharCode(n);
    })
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The text for a page yt-dlp cannot read.
String notAVideoText(String? ytDlpError) =>
    ytDlpError == null ? 'Not a video' : "Not a video (and yt-dlp couldn't read it: $ytDlpError)";

/// The text for a page with only split or HLS streams.
const noSingleFileText = 'This page has no single-file video to pass on (only separate video and audio '
    "streams). Choose 'Everyone fetches it' instead.";

class LinkProbeException implements Exception {
  final String message;
  const LinkProbeException(this.message);
  @override
  String toString() => message;
}

/// What [probeLink] found.
class LinkProbe {
  final Uri url;
  final bool isPage;
  /// A file's byte size; -1 when unknown or a page.
  final int size;
  /// yt-dlp's answer for a page it could read.
  final YtDlpInfo? info;
  /// A page's title from its HTML when yt-dlp could not read it.
  final String? pageTitle;
  /// Why yt-dlp could not read the page.
  final String? ytDlpError;
  const LinkProbe.file(this.url, this.size)
      : isPage = false,
        info = null,
        pageTitle = null,
        ytDlpError = null;
  const LinkProbe.page(this.url, {this.info, this.pageTitle, this.ytDlpError})
      : isPage = true,
        size = -1;

  /// The name to show: yt-dlp's title, the page's, else the host; null
  /// for a file (named by its file name).
  String? get title {
    if (!isPage) return null;
    final t = info?.title ?? pageTitle ?? '';
    return t.isNotEmpty ? t : url.host;
  }

  /// Why a relay cannot read this link, or null when it can.
  String? get relayProblem => !isPage
      ? null
      : info == null
          ? notAVideoText(ytDlpError)
          : info!.single == null
              ? noSingleFileText
              : null;
}

const _probeLimit = 512 * 1024;

/// Finds out what [url] is: a `Range: bytes=0-0` GET; a media file is
/// done, anything else goes to yt-dlp ([ytDlp] null: no yt-dlp), and when
/// yt-dlp cannot read it, the page's own title. Throws
/// [LinkProbeException] when the link cannot be reached at all.
Future<LinkProbe> probeLink(Uri url, {YtDlp? ytDlp, HttpClient? client}) async {
  final c = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
  try {
    String? body;
    Object? getError;
    try {
      final req = await c.getUrl(url).timeout(const Duration(seconds: 15));
      req.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final type = res.headers.contentType?.mimeType ?? '';
      if (looksLikeMediaFile(status: res.statusCode, contentType: type, url: url)) {
        await res.drain<void>().catchError((_) {});
        final total = res.headers.value(HttpHeaders.contentRangeHeader)?.split('/').last;
        final n = int.tryParse(total ?? '') ?? (res.statusCode == 200 ? res.contentLength : -1);
        return LinkProbe.file(url, n > 0 ? n : -1);
      }
      body = type.contains('html') ? await _readText(res) : null;
      if (body == null) await res.drain<void>().catchError((_) {});
    } catch (e) {
      getError = e;
    }
    String? ytErr;
    if (ytDlp != null) {
      try {
        return LinkProbe.page(url, info: await ytDlp.resolve(url.toString()));
      } catch (e) {
        ytErr = '$e';
      }
    }
    if (getError != null) {
      throw LinkProbeException('cannot open the link: $getError${ytErr == null ? '' : ' (yt-dlp: $ytErr)'}');
    }
    // A server honouring the Range sent one byte of the page: get it all.
    if (body != null && body.length < 2) {
      try {
        final req = await c.getUrl(url).timeout(const Duration(seconds: 15));
        body = await _readText(await req.close().timeout(const Duration(seconds: 15)));
      } catch (_) {}
    }
    return LinkProbe.page(url, pageTitle: body == null ? null : htmlTitle(body), ytDlpError: ytErr);
  } finally {
    if (client == null) c.close(force: true);
  }
}

Future<String> _readText(HttpClientResponse res) async {
  final out = BytesBuilder(copy: false);
  try {
    await for (final chunk in res.timeout(const Duration(seconds: 15))) {
      out.add(chunk);
      if (out.length >= _probeLimit) break;
    }
  } catch (_) {}
  return utf8.decode(out.takeBytes(), allowMalformed: true);
}

/// A page's single-file format (see [YtDlpInfo.single]), range-read with
/// yt-dlp's headers. Format URLs expire: on 403/410 the page is resolved
/// again once and the read goes on from where it stopped.
class PageRelayBytes implements RelayBytes {
  final Uri page;
  final YtDlp ytDlp;
  YtDlpFormat? _format;
  HttpRelayBytes? _inner;
  int? _size;
  var _gen = 0;
  Future<void>? _refreshing;
  PageRelayBytes(this.page, this.ytDlp, {YtDlpFormat? format}) : _format = format;

  Future<YtDlpFormat> _resolve() async {
    final f = (await ytDlp.resolve(page.toString())).single;
    if (f == null) throw const LinkProbeException(noSingleFileText);
    return f;
  }

  Future<HttpRelayBytes> _open() async =>
      _inner ??= () {
        final f = _format!;
        return HttpRelayBytes(f.url, headers: f.headers);
      }();

  static bool _expired(Object e) => e is UpstreamHttpException && (e.status == 403 || e.status == 410);

  Future<void> _refresh(int gen) {
    if (gen != _gen) return Future.value();
    return _refreshing ??= () async {
      try {
        final f = await _resolve();
        final old = _inner;
        _format = f;
        _inner = null;
        _gen++;
        await old?.close();
      } finally {
        _refreshing = null;
      }
    }();
  }

  @override
  Future<int> size() async {
    if (_size != null) return _size!;
    _format ??= await _resolve();
    final gen = _gen;
    try {
      return _size = await (await _open()).size();
    } catch (e) {
      if (!_expired(e)) rethrow;
      await _refresh(gen);
      return _size = await (await _open()).size();
    }
  }

  @override
  Stream<List<int>> read(int start, int end) async* {
    var pos = start;
    var retried = false;
    while (true) {
      final gen = _gen;
      final inner = await _open();
      try {
        await for (final chunk in inner.read(pos, end)) {
          pos += chunk.length;
          yield chunk;
        }
        return;
      } catch (e) {
        if (retried || !_expired(e)) rethrow;
        retried = true;
        await _refresh(gen);
        final n = await (await _open()).size();
        if (_size != null && n != _size) throw const LinkProbeException('the video changed on the page');
      }
    }
  }

  @override
  Future<void> close() async => _inner?.close();
}

/// A link of either kind: probed on first [size] (or given [probe]), then
/// read as a file ([HttpRelayBytes]) or a page ([PageRelayBytes]). Throws
/// [LinkProbeException] with the reason when it cannot be relayed.
class LinkRelayBytes implements RelayBytes {
  final Uri url;
  final YtDlp? ytDlp;
  LinkProbe? _probe;
  RelayBytes? _inner;
  LinkRelayBytes(this.url, {this.ytDlp, LinkProbe? probe}) : _probe = probe;

  /// The probe, after [size].
  LinkProbe? get probe => _probe;

  @override
  Future<int> size() async {
    if (_inner == null) {
      final probe = _probe ??= await probeLink(url, ytDlp: ytDlp);
      final problem = probe.relayProblem;
      if (problem != null) throw LinkProbeException(problem);
      _inner = probe.isPage ? PageRelayBytes(url, ytDlp!, format: probe.info!.single) : HttpRelayBytes(url);
    }
    return _inner!.size();
  }

  @override
  Stream<List<int>> read(int start, int end) {
    final inner = _inner;
    if (inner == null) return Stream.error(StateError('size() first'));
    return inner.read(start, end);
  }

  @override
  Future<void> close() async => _inner?.close();
}
