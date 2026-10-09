import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'cookies.dart';
import 'logging.dart';

// yt-dlp: turns a web page (YouTube, Twitter/X, ...) into media URLs. The
// app and the server each keep their own copy, the official standalone
// build downloaded from GitHub and checked against the release's
// SHA2-256SUMS, refreshed at most once a day. Nothing is installed by hand.

final _log = createLogger('yt-dlp');

class YtDlpException implements Exception {
  final String message;
  const YtDlpException(this.message);
  @override
  String toString() => message;
}

/// One playable format of a resolved page: a URL and the headers yt-dlp
/// says to send with it.
class YtDlpFormat {
  final String id;
  final Uri url;
  final Map<String, String> headers;
  final int? height;
  final String ext;
  /// yt-dlp's `downloader_options.http_chunk_size`: the longest GET the
  /// site serves at full speed.
  final int? chunkSize;
  const YtDlpFormat(
      {required this.id, required this.url, this.headers = const {}, this.height, this.ext = '', this.chunkSize});

  static YtDlpFormat _of(Map f) {
    final headers = f['http_headers'];
    final opts = f['downloader_options'];
    final chunk = opts is Map ? opts['http_chunk_size'] : null;
    final h = f['height'] is num ? (f['height'] as num).toInt() : 0;
    return YtDlpFormat(
      id: '${f['format_id'] ?? ''}',
      url: Uri.parse(f['url'] as String),
      headers: headers is Map ? {for (final e in headers.entries) '${e.key}': '${e.value}'} : const {},
      height: h == 0 ? null : h,
      ext: '${f['ext']}',
      chunkSize: chunk is num && chunk > 0 ? chunk.toInt() : null,
    );
  }
}

/// A format a relay plays as one of a media's tracks ([kind] `video` or
/// `audio`; empty for a single file holding both).
typedef YtDlpTrack = ({String kind, YtDlpFormat format});

/// What `yt-dlp -J` says about a page.
class YtDlpInfo {
  final String title;
  final String uploader;
  final String extractor;
  final String webpageUrl;
  /// Seconds; null when unknown (a live stream).
  final double? duration;
  final String? thumbnail;
  /// A live stream (never relayed).
  final bool isLive;
  /// What a relay range-reads (see [pickTracks]): one file, or a video and
  /// an audio file; empty when the page has neither (only streaming
  /// playlists, or live).
  final List<YtDlpTrack> tracks;
  /// Every plain http(s) format by id, to find [tracks] again after a
  /// re-resolve.
  final Map<String, YtDlpFormat> formats;
  const YtDlpInfo({
    required this.title,
    this.uploader = '',
    this.extractor = '',
    this.webpageUrl = '',
    this.duration,
    this.thumbnail,
    this.isLive = false,
    this.tracks = const [],
    this.formats = const {},
  });

  /// Parses `yt-dlp -J` output; a playlist answer uses its first entry.
  static YtDlpInfo parse(Map<String, Object?> j) {
    final entries = j['entries'];
    if (j['_type'] == 'playlist' && entries is List) {
      final first = entries.whereType<Map>().firstOrNull;
      if (first == null) throw const YtDlpException('the page has no videos');
      return parse(Map<String, Object?>.from(first));
    }
    String str(String k) => j[k] is String ? (j[k] as String).trim() : '';
    final formats = j['formats'] is List ? (j['formats'] as List) : [if (j['url'] is String) j];
    final isLive = j['is_live'] == true || j['live_status'] == 'is_live' || j['live_status'] == 'is_upcoming';
    return YtDlpInfo(
      title: str('title').isNotEmpty ? str('title') : str('fulltitle'),
      uploader: str('uploader').isNotEmpty ? str('uploader') : str('channel'),
      extractor: str('extractor_key').isNotEmpty ? str('extractor_key') : str('extractor'),
      webpageUrl: str('webpage_url'),
      duration: j['duration'] is num ? (j['duration'] as num).toDouble() : null,
      thumbnail: str('thumbnail').isEmpty ? null : str('thumbnail'),
      isLive: isLive,
      tracks: isLive ? const [] : pickTracks(formats),
      formats: {
        for (final f in formats)
          if (_httpUrl(f) && f is Map) '${f['format_id'] ?? ''}': YtDlpFormat._of(f),
      },
    );
  }
}

const _singleFileExts = {'mp4', 'webm', 'mov', 'm4v', 'mkv'};
const _audioExts = {'m4a', 'mp4', 'webm', 'opus', 'ogg', 'mp3'};

/// A plain http(s) format with a URL, not DRM-protected.
bool _httpUrl(Object? f) {
  if (f is! Map || f['has_drm'] == true) return false;
  final url = f['url'];
  final protocol = f['protocol'];
  if (url is! String || (protocol != 'http' && protocol != 'https')) return false;
  final uri = Uri.tryParse(url);
  return uri != null && (uri.isScheme('http') || uri.isScheme('https'));
}

int _height(Map f) => f['height'] is num ? (f['height'] as num).toInt() : 0;
double _tbr(Map f) =>
    f['tbr'] is num ? (f['tbr'] as num).toDouble() : (f['abr'] is num ? (f['abr'] as num).toDouble() : 0);

/// Height order: up to [maxHeight] the tallest first, then the shortest
/// above it.
int _byHeight(int ha, int hb, int maxHeight) {
  final ina = ha <= maxHeight, inb = hb <= maxHeight;
  if (ina != inb) return ina ? -1 : 1;
  return ha == hb ? 0 : (ina ? hb.compareTo(ha) : ha.compareTo(hb));
}

/// The best single-file format of [formats] (yt-dlp format maps): video
/// and audio both present (or not known to be absent), plain http(s), a
/// video container; the tallest up to [maxHeight], else the shortest above
/// it; mp4/webm and higher bitrate break ties.
YtDlpFormat? pickSingleFile(List<Object?> formats, {int maxHeight = 1080}) {
  final ok = [
    for (final f in formats)
      if (_httpUrl(f) && (f as Map)['vcodec'] != 'none' && f['acodec'] != 'none' && _singleFileExts.contains(f['ext']))
        f,
  ];
  if (ok.isEmpty) return null;
  bool mp4(Map f) => f['ext'] == 'mp4' || f['ext'] == 'webm';
  ok.sort((a, b) {
    final h = _byHeight(_height(a), _height(b), maxHeight);
    if (h != 0) return h;
    if (mp4(a) != mp4(b)) return mp4(a) ? -1 : 1;
    return _tbr(b).compareTo(_tbr(a));
  });
  return YtDlpFormat._of(ok.first);
}

// Relayed bytes cost every viewer bandwidth and the server buffer, and mpv
// decodes all of these: the most compact codec first. HEVC (hardware
// decoding nearly everywhere), then AV1 (smallest; software is fine to
// 1080p), then VP9, then h264.
int _videoCodecRank(Map f) {
  final c = '${f['vcodec']}'.toLowerCase();
  if (c.startsWith('hvc') || c.startsWith('hev') || c.startsWith('h265')) return 0;
  if (c.startsWith('av01')) return 1;
  if (c.startsWith('vp9') || c.startsWith('vp09')) return 2;
  if (c.startsWith('avc') || c.startsWith('h264')) return 3;
  return 4;
}

/// The best video-only + audio-only pair of plain http(s) files (YouTube's
/// DASH formats), or null. Video: the tallest up to [maxHeight] (else the
/// shortest above), HEVC before AV1 before VP9 before h264 (smallest
/// first, see [_videoCodecRank]), then bitrate. Audio: the original language, not a `-drc` variant, m4a/aac
/// before others (opus), then bitrate.
(YtDlpFormat, YtDlpFormat)? pickSplit(List<Object?> formats, {int maxHeight = 1080}) {
  final video = [
    for (final f in formats)
      if (_httpUrl(f) && (f as Map)['acodec'] == 'none' && f['vcodec'] is String && f['vcodec'] != 'none' &&
          _singleFileExts.contains(f['ext']))
        f,
  ];
  final audio = [
    for (final f in formats)
      if (_httpUrl(f) && (f as Map)['vcodec'] == 'none' && f['acodec'] is String && f['acodec'] != 'none' &&
          _audioExts.contains(f['ext']))
        f,
  ];
  if (video.isEmpty || audio.isEmpty) return null;
  video.sort((a, b) {
    final h = _byHeight(_height(a), _height(b), maxHeight);
    if (h != 0) return h;
    final c = _videoCodecRank(a).compareTo(_videoCodecRank(b));
    return c != 0 ? c : _tbr(b).compareTo(_tbr(a));
  });
  bool drc(Map f) => '${f['format_id']}'.contains('drc');
  int lang(Map f) => f['language_preference'] is num ? (f['language_preference'] as num).toInt() : 0;
  bool aac(Map f) => f['ext'] == 'm4a' || '${f['acodec']}'.startsWith('mp4a');
  audio.sort((a, b) {
    if (drc(a) != drc(b)) return drc(a) ? 1 : -1;
    final l = lang(b).compareTo(lang(a));
    if (l != 0) return l;
    if (aac(a) != aac(b)) return aac(a) ? -1 : 1;
    return _tbr(b).compareTo(_tbr(a));
  });
  return (YtDlpFormat._of(video.first), YtDlpFormat._of(audio.first));
}

/// What a relay reads of [formats]: the single file ([pickSingleFile])
/// unless a video + audio pair ([pickSplit]) is taller (both by the
/// [maxHeight] rule); empty when there is neither.
List<YtDlpTrack> pickTracks(List<Object?> formats, {int maxHeight = 1080}) {
  final single = pickSingleFile(formats, maxHeight: maxHeight);
  final split = pickSplit(formats, maxHeight: maxHeight);
  if (split != null &&
      (single == null ||
          (single.height != null &&
              split.$1.height != null &&
              _byHeight(split.$1.height!, single.height!, maxHeight) < 0))) {
    return [(kind: 'video', format: split.$1), (kind: 'audio', format: split.$2)];
  }
  return single == null ? const [] : [(kind: '', format: single)];
}

/// The official standalone build for this platform, or null if there is
/// none.
String? ytDlpAssetName(Abi abi, {bool musl = false}) => switch (abi) {
      Abi.linuxX64 => musl ? 'yt-dlp_musllinux' : 'yt-dlp_linux',
      Abi.linuxArm64 => musl ? 'yt-dlp_musllinux_aarch64' : 'yt-dlp_linux_aarch64',
      Abi.windowsX64 => 'yt-dlp.exe',
      Abi.windowsArm64 => 'yt-dlp_arm64.exe',
      Abi.windowsIA32 => 'yt-dlp_x86.exe',
      Abi.macosX64 || Abi.macosArm64 => 'yt-dlp_macos',
      _ => null,
    };

/// `SHA2-256SUMS` lines (`<hex>  <name>`) as name -> lowercase hex.
Map<String, String> parseSha256Sums(String text) => {
      for (final line in const LineSplitter().convert(text))
        if (RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$').firstMatch(line) case final m?)
          m.group(2)!: m.group(1)!.toLowerCase(),
    };

/// The last `ERROR:` line of yt-dlp's stderr without its prefixes
/// (`ERROR: [twitter] 123: No video` -> `No video`), else the last line.
String ytDlpErrorText(String stderr) {
  final lines = const LineSplitter().convert(stderr).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return 'yt-dlp failed';
  final err = lines.lastWhere((l) => l.startsWith('ERROR:'), orElse: () => lines.last);
  return err.replaceFirst(RegExp(r'^ERROR:\s*'), '').replaceFirst(RegExp(r'^\[[^\]]+\]\s*[^:\s]*:\s*'), '');
}

/// Finds, downloads, updates and runs yt-dlp. The managed copy lives in
/// [dir] (writable); without it a `yt-dlp` on PATH is the fallback when
/// the download fails. Every failure is non-fatal: [lastError] says why.
class YtDlp {
  final String dir;
  final bool enabled;
  /// How often [ensure] looks for a newer release in the background.
  final Duration updateEvery;
  final HttpClient Function() _http;
  static const releases = 'https://github.com/yt-dlp/yt-dlp/releases';

  YtDlp(this.dir, {this.enabled = true, this.updateEvery = const Duration(days: 1), HttpClient Function()? http})
      : _http = http ?? HttpClient.new;

  String? _path;
  /// The binary in use, once found.
  String? get path => _path;
  /// `yt-dlp --version` of [path].
  String? version;
  String? lastError;
  /// A download or update is running.
  bool busy = false;
  final _changes = StreamController<void>.broadcast();
  /// Fires when [version], [lastError] or [busy] change.
  Stream<void> get changes => _changes.stream;
  Future<String?>? _ensuring;
  Future<void>? _updating;

  /// Cookies every resolve sends (see [YtDlpCookies]), kept in [dir].
  late final cookies = YtDlpCookies(dir);

  String get managedPath => p.join(dir, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp');
  String get _stampPath => p.join(dir, 'last-check');

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _fail(String message) {
    lastError = message;
    _log.warning(message);
    _changed();
  }

  /// The binary to run, downloading it first if needed; null (see
  /// [lastError]) when there is none. A newer release is looked for in the
  /// background at most every [updateEvery].
  Future<String?> ensure() {
    final known = _path;
    if (known != null && (known == 'yt-dlp' || File(known).existsSync())) {
      unawaited(update());
      return Future.value(known);
    }
    return _ensuring ??= _ensure().whenComplete(() => _ensuring = null);
  }

  Future<String?> _ensure() async {
    if (!enabled) {
      lastError = 'yt-dlp is turned off';
      return null;
    }
    if (await File(managedPath).exists()) {
      final v = await _versionOf(managedPath);
      if (v != null) {
        _use(managedPath, v);
        unawaited(update());
        return managedPath;
      }
    }
    try {
      await _download(await _latestTag());
      return managedPath;
    } catch (e) {
      final onPath = await _versionOf('yt-dlp');
      if (onPath != null) {
        _use('yt-dlp', onPath);
        _fail('could not download yt-dlp ($e); using the one on PATH');
        return 'yt-dlp';
      }
      _fail('could not download yt-dlp: $e');
      return null;
    }
  }

  void _use(String path, String v) {
    _path = path;
    version = v;
    _changed();
  }

  Future<String?> _versionOf(String exe) async {
    try {
      final r = await Process.run(exe, ['--version']).timeout(const Duration(seconds: 20));
      final v = '${r.stdout}'.trim();
      return r.exitCode == 0 && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Replaces the managed copy when a newer release is out. Without
  /// [force], at most every [updateEvery] (remembered across restarts).
  Future<void> update({bool force = false}) => _updating ??= _update(force).whenComplete(() => _updating = null);

  Future<void> _update(bool force) async {
    if (!enabled) return;
    try {
      if (!force) {
        final stamp = File(_stampPath);
        if (await stamp.exists()) {
          final at = DateTime.tryParse((await stamp.readAsString()).trim());
          if (at != null && DateTime.now().difference(at) < updateEvery) return;
        }
      }
      final tag = await _latestTag();
      final managed = await File(managedPath).exists() ? await _versionOf(managedPath) : null;
      if (managed != tag) {
        await _download(tag);
      } else {
        _use(managedPath, managed!);
        await _stamp();
      }
      if (lastError != null) {
        lastError = null;
        _changed();
      }
    } catch (e) {
      _fail('yt-dlp update failed: $e');
    }
  }

  Future<void> _stamp() async {
    try {
      await File(_stampPath).writeAsString(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// The tag `releases/latest` redirects to.
  Future<String> _latestTag() async {
    final client = _http();
    try {
      final req = await client.getUrl(Uri.parse('$releases/latest')).timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>().catchError((_) {});
      final loc = res.headers.value(HttpHeaders.locationHeader) ?? '';
      final tag = Uri.tryParse(loc)?.pathSegments.lastOrNull ?? '';
      if (!res.isRedirect || tag.isEmpty || tag == 'latest') {
        throw YtDlpException('no latest release (HTTP ${res.statusCode})');
      }
      return tag;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _download(String tag) async {
    final asset = ytDlpAssetName(Abi.current(), musl: _isMusl());
    if (asset == null) throw YtDlpException('no yt-dlp build for ${Abi.current()}');
    busy = true;
    _changed();
    final client = _http();
    final part = File('$managedPath.part$pid');
    try {
      await Directory(dir).create(recursive: true);
      final sums = parseSha256Sums(utf8.decode(await _get(client, '$releases/download/$tag/SHA2-256SUMS')));
      final want = sums[asset];
      if (want == null) throw YtDlpException('$asset is not in the release checksums');
      _log.info('downloading yt-dlp $tag ($asset)');
      final req = await client.getUrl(Uri.parse('$releases/download/$tag/$asset')).timeout(const Duration(seconds: 30));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>().catchError((_) {});
        throw YtDlpException('download HTTP ${res.statusCode}');
      }
      final sink = part.openWrite();
      final hashOut = _DigestSink();
      final hasher = sha256.startChunkedConversion(hashOut);
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        hasher.add(chunk);
        sink.add(chunk);
      }
      hasher.close();
      await sink.close();
      if (hashOut.value.toString() != want) throw const YtDlpException('checksum mismatch');
      if (!Platform.isWindows) {
        final r = await Process.run('chmod', ['755', part.path]);
        if (r.exitCode != 0) throw YtDlpException('chmod failed: ${r.stderr}');
      }
      final v = await _versionOf(part.path);
      if (v == null) throw const YtDlpException('the downloaded yt-dlp does not run');
      final target = File(managedPath);
      // Windows cannot rename onto an existing file.
      if (Platform.isWindows && await target.exists()) await target.delete();
      await part.rename(managedPath);
      _use(managedPath, v);
      await _stamp();
      _log.info('yt-dlp $v ready at $managedPath');
    } finally {
      client.close(force: true);
      if (await part.exists()) await part.delete().catchError((_) => part);
      busy = false;
      _changed();
    }
  }

  Future<List<int>> _get(HttpClient client, String url) async {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      await res.drain<void>().catchError((_) {});
      throw YtDlpException('$url: HTTP ${res.statusCode}');
    }
    final out = BytesBuilder(copy: false);
    await for (final c in res.timeout(const Duration(seconds: 20))) {
      out.add(c);
    }
    return out.takeBytes();
  }

  static bool _isMusl() {
    if (!Platform.isLinux) return false;
    try {
      return Directory('/lib').listSync().any((e) => p.basename(e.path).startsWith('ld-musl-'));
    } catch (_) {
      return false;
    }
  }

  /// Asks yt-dlp what [url] is, with [cookies] if any. Throws
  /// [YtDlpException] with yt-dlp's own reason on failure.
  Future<YtDlpInfo> resolve(String url, {Duration timeout = const Duration(seconds: 25)}) async {
    final exe = await ensure();
    if (exe == null) throw YtDlpException(lastError ?? 'yt-dlp is not available');
    final proc = await Process.start(exe, resolveArgs(url));
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      throw YtDlpException('yt-dlp took longer than ${timeout.inSeconds} s');
    }
    if (code != 0) throw YtDlpException(ytDlpErrorText(await err));
    try {
      final j = jsonDecode(await out);
      if (j is! Map) throw const FormatException('not an object');
      return YtDlpInfo.parse(Map<String, Object?>.from(j));
    } on FormatException catch (e) {
      throw YtDlpException('unreadable yt-dlp output: ${e.message}');
    }
  }

  /// The command line [resolve] runs.
  List<String> resolveArgs(String url) =>
      ['-J', '--no-playlist', '--no-warnings', '--ignore-config', ...cookies.args(), '--', url];

  Future<void> close() => _changes.close();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
