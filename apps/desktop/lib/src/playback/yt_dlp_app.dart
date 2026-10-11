import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sync_relay_core/core.dart';

/// mpv's `ytdl-format` for links every player opens itself.
const ytdlFormat = 'bv*[height<=1080]+ba/b';

/// yt-dlp's `--sub-langs` for mpv's hook (its default is `all`), without
/// Bilibili's danmaku: an XML comment feed served raw-deflate, which
/// ffmpeg fails to inflate on every read (a warning each time) while the
/// video waits on it.
const ytdlSubLangs = 'all,-danmaku';

/// The app's yt-dlp (see [YtDlp]): in the app-support folder, shared with
/// the hosted server. [probe] remembers what pasted links are for a while,
/// so the Link preview and the swap ask once.
class AppYtDlp {
  static final instance = AppYtDlp();

  /// [ytDlp]: a given one (tests); default in the app-support folder.
  AppYtDlp([YtDlp? ytDlp]) : _ytDlp = ytDlp == null ? null : Future.value(ytDlp);

  Future<YtDlp>? _ytDlp;
  Future<YtDlp> get ytDlp => _ytDlp ??= () async {
        final base = await getApplicationSupportDirectory();
        return YtDlp(dir(base.path));
      }();

  static String dir(String appSupport) => '$appSupport${Platform.pathSeparator}yt-dlp';

  /// Gets yt-dlp ready in the background (download on first run, a daily
  /// update check afterwards).
  void warmUp() => unawaited(ytDlp.then((y) => y.ensure()).catchError((_) => null));

  /// mpv's `ytdl-raw-options`: [ytdlSubLangs] and the cookies in the
  /// yt-dlp folder (see [YtDlpCookies]).
  Future<String> mpvRawOptions() async {
    const subs = 'sub-langs=%${ytdlSubLangs.length}%$ytdlSubLangs';
    try {
      final cookies = (await ytDlp).cookies.mpvRawOptions();
      return cookies.isEmpty ? subs : '$subs,$cookies';
    } catch (_) {
      return subs;
    }
  }

  final _probes = <String, ({DateTime at, DateTime until, Future<LinkProbe> f})>{};
  static const _probeTtl = Duration(minutes: 10);

  /// What [url] is, from memory while it is kept (10 minutes from when it
  /// was probed; [keep] keeps it longer, for Up next's first item, which
  /// is probed again before that runs out). [fresh] probes again: the
  /// remembered result stays until the new one is in, and stays when the
  /// new one fails.
  Future<LinkProbe> probe(String url, {Duration keep = _probeTtl, bool fresh = false}) {
    final now = DateTime.now();
    _probes.removeWhere((_, v) => now.isAfter(v.until));
    final hit = _probes[url];
    if (hit != null && !fresh) {
      final longer = hit.at.add(keep);
      if (longer.isAfter(hit.until)) _probes[url] = (at: hit.at, until: longer, f: hit.f);
      return hit.f;
    }
    final f = ytDlp.then((y) => probeLink(Uri.parse(url), ytDlp: y));
    final until = now.add(keep);
    if (hit == null) {
      _probes[url] = (at: now, until: until, f: f);
      f.catchError((Object _) {
        if (_probes[url]?.f == f) _probes.remove(url);
        return LinkProbe.file(Uri(), -1);
      });
    } else {
      f.then<void>((_) {
        _probes[url] = (at: now, until: until, f: f);
      }, onError: (Object _) {});
    }
    return f;
  }

  /// [url] no longer needs keeping longer: back to the usual 10 minutes.
  void release(String url) {
    final hit = _probes[url];
    if (hit == null) return;
    final usual = hit.at.add(_probeTtl);
    if (usual.isBefore(hit.until)) _probes[url] = (at: hit.at, until: usual, f: hit.f);
  }
}
