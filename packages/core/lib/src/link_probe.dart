import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'constants.dart';
import 'logging.dart';
import 'relay.dart';
import 'relay_pieces.dart';
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

/// The text for a page with no video a relay can read.
const noRelayFormatText = "This page has no video a relay can read. Choose 'Everyone fetches it' instead.";

/// The plain-words texts of [playErrorText].
const needsCookiesText = 'This site needs cookies — Settings → Library & accounts → Web links → Cookies';
/// yt-dlp read the page but got no video, typically a site that hides it
/// from signed-out visitors (Bilibili does for some videos).
const noFormatsText = 'No video found: it may need signing in (cookies: Settings → Library & accounts → Web links)';
const notAllowedText = 'Not allowed (403)';
const notFoundText = 'Not found (404)';
const unsupportedUrlText = 'Not a video page yt-dlp knows';
const unreachableText = "Couldn't reach the site";
const _plainTexts = {needsCookiesText, notAllowedText, notFoundText, unsupportedUrlText, unreachableText};

final _cookiesHint = RegExp(r'\b412\b|precondition|log ?in\b|logged|cookies|sign ?in\b', caseSensitive: false);
final _forbidden = RegExp(r'(^|[\s(:])403\b|forbidden', caseSensitive: false);
final _notFound = RegExp(r'(^|[\s(:])404\b|\b410\b|not found', caseSensitive: false);
final _unreachable = RegExp(
    r'SocketException|HandshakeException|TimeoutException|timed out|failed host lookup|connection (refused|reset|closed)|'
    r'network is unreachable|no route to host|name or service not known|getaddrinfo|unable to download webpage',
    caseSensitive: false);

/// yt-dlp's [error] (plain words or raw) may be about signing in: worth
/// saying which cookies were used (D11).
bool mayNeedSignIn(String error) {
  final t = playErrorText(error);
  return t == needsCookiesText || t == noFormatsText;
}

/// [plain] ([playErrorText]) with the cookies [note] (D11), for the two
/// texts about signing in; anything else as is.
String withCookieNote(String plain, String? note) {
  if (note == null || note.isEmpty) return plain;
  if (plain == needsCookiesText) return 'This site needs cookies ($note) — Settings → Library & accounts → Web links → Cookies';
  if (plain == noFormatsText) return 'No video found: it may need signing in ($note)';
  return plain;
}

/// Why a link or media cannot be played, in plain words, from the raw
/// error of yt-dlp, ffmpeg/mpv or the link probe; anything it does not
/// know comes back as is (one line, at most 100 characters).
String playErrorText(String raw) {
  final s = raw.trim();
  // First: its message quotes the URL, which may say anything.
  if (s.toLowerCase().contains('unsupported url')) return unsupportedUrlText;
  if (_cookiesHint.hasMatch(s)) return needsCookiesText;
  if (s.toLowerCase().contains('no video formats found')) return noFormatsText;
  if (_forbidden.hasMatch(s)) return notAllowedText;
  if (_notFound.hasMatch(s)) return notFoundText;
  if (_unreachable.hasMatch(s)) return unreachableText;
  final line = s.replaceAll(RegExp(r'\s+'), ' ');
  if (line.isEmpty) return "Couldn't open it";
  return line.length > 100 ? '${line.substring(0, 99)}…' : line;
}

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

  /// Which cookies that run used ([YtDlp.cookieNote]), when it may be about
  /// signing in.
  final String? cookies;
  /// The HTTP status of the probe's GET; 0 when unknown.
  final int status;
  const LinkProbe.file(this.url, this.size)
      : isPage = false,
        info = null,
        pageTitle = null,
        ytDlpError = null,
        cookies = null,
        status = 0;
  const LinkProbe.page(this.url, {this.info, this.pageTitle, this.ytDlpError, this.cookies, this.status = 0})
      : isPage = true,
        size = -1;

  /// Why nobody may be able to play this link ([playErrorText]), or null
  /// when it looks playable: a page yt-dlp could not read, or a link
  /// answering 4xx.
  String? get problem {
    if (!isPage || info != null) return null;
    final err = ytDlpError == null ? null : playErrorText(ytDlpError!);
    // A 4xx says more than yt-dlp's words it has no plain text for.
    final known = err != null && _plainTexts.contains(err);
    if (!known && status >= 400 && status < 500) return playErrorText('HTTP Error $status');
    return err == null ? null : withCookieNote(err, cookies);
  }

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
          : info!.isLive
              ? liveStreamText
              : info!.tracks.isEmpty
                  ? noRelayFormatText
                  : null;
}

final _log = createLogger('link');

const _probeLimit = 512 * 1024;

/// Finds out what [url] is: a `Range: bytes=0-0` GET; a media file is
/// done, anything else goes to yt-dlp ([ytDlp] null: no yt-dlp), and when
/// yt-dlp cannot read it, the page's own title. Throws
/// [LinkProbeException] when the link cannot be reached at all.
Future<LinkProbe> probeLink(Uri url, {YtDlp? ytDlp, HttpClient? client}) async {
  final p = await _probeLink(url, ytDlp: ytDlp, client: client);
  _log.info('probe ${logUrl(url)}: ${p.isPage ? 'page' : 'file of ${p.size} bytes'}'
      '${p.status == 0 ? '' : ', HTTP ${p.status}'}'
      '${p.info == null ? '' : ', yt-dlp read it'}'
      '${p.ytDlpError == null ? '' : ', yt-dlp: ${p.ytDlpError}'}'
      '${p.problem == null ? '' : '; problem: ${p.problem}'}'
      '${p.relayProblem == null ? '' : '; relay: ${p.relayProblem}'}');
  return p;
}

Future<LinkProbe> _probeLink(Uri url, {YtDlp? ytDlp, HttpClient? client}) async {
  final c = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
  try {
    String? body;
    Object? getError;
    var status = 0;
    try {
      final req = await c.getUrl(url).timeout(const Duration(seconds: 15));
      req.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=0-0')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 15));
      status = res.statusCode;
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
    String? ytErr, cookies;
    if (ytDlp != null) {
      try {
        return LinkProbe.page(url, info: await ytDlp.resolve(url.toString()), status: status);
      } catch (e) {
        ytErr = '$e';
        if (e is YtDlpException) cookies = e.cookies;
      }
    }
    if (getError != null) {
      _log.warning('probe ${logUrl(url)}: cannot open it: $getError${ytErr == null ? '' : ' (yt-dlp: $ytErr)'}');
      throw LinkProbeException('cannot open the link: $getError${ytErr == null ? '' : ' (yt-dlp: $ytErr)'}');
    }
    // A server honouring the Range sent one byte of the page: get it all.
    if (body != null && body.length < 2) {
      try {
        final req = await c.getUrl(url).timeout(const Duration(seconds: 15));
        body = await _readText(await req.close().timeout(const Duration(seconds: 15)));
      } catch (_) {}
    }
    return LinkProbe.page(url,
        pageTitle: body == null ? null : htmlTitle(body), ytDlpError: ytErr, cookies: cookies, status: status);
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

/// A page's relay tracks (see [YtDlpInfo.tracks]: one file, video +
/// audio, or segmented playlists). A byte track is range-read with
/// yt-dlp's headers in GETs of the format's `http_chunk_size`; a pieces
/// track's playlist (or DASH fragments) is read on first use, then each
/// piece is one GET. Format URLs expire: on 403/410/412 from any track the
/// page is resolved again once for all tracks (same format ids, same sizes
/// and piece counts) and the read goes on from where it stopped. Another
/// expiry within [refreshGap] of that resolve fails the read instead (the
/// server backs off and asks again), so a site refusing the fresh URLs too
/// is not resolved again and again.
class PageRelayMedia implements RelayMedia {
  final Uri page;
  final YtDlp ytDlp;
  List<YtDlpTrack>? _picked;
  List<HttpRelayBytes?> _inner = const [];
  List<UpstreamPieces?> _pieces = const [];
  List<RelayTrack>? _tracks;
  final _sizes = <int, int>{};
  final _http = HttpClient();
  var _gen = 0;
  Future<void>? _refreshing;
  DateTime? _refreshedAt;
  final Duration refreshGap;
  PageRelayMedia(this.page, this.ytDlp, {List<YtDlpTrack>? tracks, this.refreshGap = const Duration(seconds: 60)})
      : _picked = tracks;

  Future<YtDlpInfo> _info() async {
    final info = await ytDlp.resolve(page.toString());
    if (info.isLive) throw const LinkProbeException(liveStreamText);
    return info;
  }

  @override
  Future<List<RelayTrack>> open() async {
    if (_tracks != null) return _tracks!;
    final picked = _picked ??= (await _info()).tracks;
    if (picked.isEmpty) throw const LinkProbeException(noRelayFormatText);
    _inner = List.filled(picked.length, null, growable: false);
    _pieces = List.filled(picked.length, null, growable: false);
    return _tracks = [
      for (var i = 0; i < picked.length; i++)
        picked[i].format.isPieces
            ? RelayTrack.pieces(picked[i].kind, _PagePieces(this, i))
            : RelayTrack(picked[i].kind, _PageTrack(this, i)),
    ];
  }

  HttpRelayBytes _open(int i) => _inner[i] ??= () {
        final f = _picked![i].format;
        return HttpRelayBytes(f.url,
            headers: f.headers, chunkSize: f.chunkSize ?? RelayConstants.relayUpstreamChunkBytes);
      }();

  /// Reads track [i]'s playlist (or DASH fragments) into pieces.
  Future<UpstreamPieces> _loadPieces(YtDlpFormat f) async {
    final frags = f.fragments;
    if (f.protocol == 'http_dash_segments') {
      if (frags == null) throw const RelayPiecesException('no DASH fragments');
      return dashPieces(frags);
    }
    return fetchHlsPlaylist(_http, f.url, f.headers);
  }

  /// A format URL the site no longer takes: 403, 410, or Bilibili's 412.
  static bool _expired(Object e) =>
      e is UpstreamHttpException && (e.status == 403 || e.status == 410 || e.status == 412);

  /// Resolves the page again: the same format ids with the same sizes and
  /// piece shapes, else the video changed.
  Future<void> _refresh(int gen, Object cause) {
    if (gen != _gen) return Future.value();
    final last = _refreshedAt;
    if (_refreshing == null && last != null && DateTime.now().difference(last) < refreshGap) {
      // Resolved a moment ago and refused again: not once more.
      return Future.error(cause);
    }
    return _refreshing ??= () async {
      _refreshedAt = DateTime.now();
      _log.info('relay of ${logUrl(page)}: a format URL expired (HTTP ${cause is UpstreamHttpException ? cause.status : '?'}), resolving the page again');
      try {
        const changed = LinkProbeException('the video changed on the page');
        final info = await _info();
        final next = <YtDlpTrack>[];
        for (final t in _picked!) {
          final f = info.formats[t.format.id];
          if (f == null || f.isPieces != t.format.isPieces) throw changed;
          next.add((kind: t.kind, format: f));
        }
        final pieces = List<UpstreamPieces?>.filled(next.length, null, growable: false);
        for (var i = 0; i < next.length; i++) {
          final had = _pieces[i];
          if (had == null) continue;
          final p = pieces[i] = await _loadPieces(next[i].format);
          if (!p.list.sameShape(had.list)) throw changed;
        }
        final old = _inner;
        _picked = next;
        _pieces = pieces;
        _inner = List.filled(next.length, null, growable: false);
        for (final e in _sizes.entries) {
          if (await _open(e.key).size() != e.value) throw changed;
        }
        _gen++;
        for (final b in old) {
          await b?.close();
        }
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<int> _size(int i) async {
    final known = _sizes[i];
    if (known != null) return known;
    final gen = _gen;
    try {
      return _sizes[i] = await _open(i).size();
    } catch (e) {
      if (!_expired(e)) rethrow;
      await _refresh(gen, e);
      return _sizes[i] = await _open(i).size();
    }
  }

  Future<UpstreamPieces> _piecesOf(int i) async {
    final known = _pieces[i];
    if (known != null) return known;
    final gen = _gen;
    try {
      return _pieces[i] = await _loadPieces(_picked![i].format);
    } catch (e) {
      if (!_expired(e)) rethrow;
      await _refresh(gen, e);
      return _pieces[i] ??= await _loadPieces(_picked![i].format);
    }
  }

  Stream<List<int>> _read(int i, int start, int end) async* {
    var pos = start;
    var retried = false;
    while (true) {
      final gen = _gen;
      try {
        await for (final chunk in _open(i).read(pos, end)) {
          pos += chunk.length;
          yield chunk;
        }
        return;
      } catch (e) {
        if (retried || !_expired(e)) rethrow;
        retried = true;
        await _refresh(gen, e);
      }
    }
  }

  /// Piece [index] of track [i]; on expiry once more after a re-resolve
  /// (nothing was sent yet: an expired URL fails before its first byte).
  Stream<List<int>> _readPiece(int i, int index) async* {
    var retried = false;
    while (true) {
      final gen = _gen;
      final p = await _piecesOf(i);
      if (index >= p.sources.length) throw RangeError.index(index, p.sources, 'piece');
      try {
        yield* readPiece(_http, p.sources[index], _picked![i].format.headers);
        return;
      } catch (e) {
        if (retried || !_expired(e)) rethrow;
        retried = true;
        await _refresh(gen, e);
      }
    }
  }

  @override
  Future<void> close() async {
    for (final b in _inner) {
      await b?.close();
    }
    _http.close(force: true);
  }
}

class _PageTrack implements RelayBytes {
  final PageRelayMedia media;
  final int index;
  _PageTrack(this.media, this.index);

  @override
  Future<int> size() => media._size(index);

  @override
  Stream<List<int>> read(int start, int end) => media._read(index, start, end);

  /// The media closes its tracks.
  @override
  Future<void> close() async {}
}

class _PagePieces implements RelayPieces {
  final PageRelayMedia media;
  final int index;
  _PagePieces(this.media, this.index);

  @override
  Future<RelayPieceList> list() async => (await media._piecesOf(index)).list;

  @override
  Stream<List<int>> read(int piece) => media._readPiece(index, piece);

  /// The media closes its tracks.
  @override
  Future<void> close() async {}
}

/// A link of either kind, probed on first [open] (or given [probe]): a
/// file as one track ([HttpRelayBytes]), a page as its picked formats
/// ([PageRelayMedia]). Throws [LinkProbeException] with the reason when it
/// cannot be relayed.
class LinkRelayMedia implements RelayMedia {
  final Uri url;
  final YtDlp? ytDlp;
  LinkProbe? _probe;
  RelayMedia? _inner;
  LinkRelayMedia(this.url, {this.ytDlp, LinkProbe? probe}) : _probe = probe;

  /// The probe, after [open].
  LinkProbe? get probe => _probe;

  @override
  Future<List<RelayTrack>> open() async {
    if (_inner == null) {
      final probe = _probe ??= await probeLink(url, ytDlp: ytDlp);
      final problem = probe.relayProblem;
      if (problem != null) throw LinkProbeException(problem);
      _inner = probe.isPage
          ? PageRelayMedia(url, ytDlp!, tracks: probe.info!.tracks)
          : RelayMedia.single(HttpRelayBytes(url));
    }
    return _inner!.open();
  }

  @override
  Future<void> close() async => _inner?.close();
}
